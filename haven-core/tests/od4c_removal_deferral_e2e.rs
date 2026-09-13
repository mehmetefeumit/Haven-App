//! OD4-c: removal-bearing auto-commits stay OUT of background bursts, and the
//! wedge that survives that is REPORTED rather than silent.
//!
//! Owner decision OD4-c takes both halves of the crash-mid-burst problem:
//!
//! * **(iv)** a background burst must not open a publish-before-apply window for
//!   a removal-bearing auto-commit. A receive-side auto-commit always removes a
//!   member (it commits a peer's `SelfRemove`), and MDK's hydrate deliberately
//!   refuses to recover a removal-bearing staged commit
//!   (`cgka-engine/src/engine.rs:820-828`, rev `e391adc`), so an OS kill between
//!   SEND and OK leaves the group with a staged commit nothing will ever publish
//!   or clear — no `PendingCommitRecovered`, and every later send refused.
//! * **(i)** the state that survives (iv) is detected and surfaced as a terminal
//!   per-circle verdict, so the user can re-invite instead of believing they are
//!   sharing.
//!
//! # Why the deferral parks the commit instead of rolling it back
//!
//! Verified at the pinned rev, by source and by experiment: rolling a peer
//! `SelfRemove` auto-commit back is a PERMANENT SILENT DROP of the removal. The
//! engine removes its in-memory `scheduled_self_remove_auto_commits` entry
//! before staging, `do_publish_failed` does not re-arm it, and a redelivery of
//! the proposal short-circuits to `Buffered` off its durable `Created` row
//! without rescheduling — so no later `advance_convergence`, no re-ingest of the
//! same proposal, no outbound send and no process restart ever re-derives it.
//! The leaver would stay in the circle, still able to derive its keys, until
//! some unrelated commit moved the epoch.
//!
//! `no_disposition_here_ever_drops_the_removal` is the test that fails if that
//! is ever traded away.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, PendingStateRef, PublishWork, TransportMessage};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::auto_commit::{
    park_or_rollback_receive_publish_work, resolve_receive_publish_work,
    resolve_receive_publish_work_with_policy, AutoCommitPublisher, ReceiveAutoCommitPolicy,
};
use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveSyncEvent, SyncStatusReason};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, capture_haven_log};

/// A recording fake relay plane: records every publish and reports a fixed
/// OK-ack verdict, so the ordering is deterministic with no network.
struct FakePublisher {
    ack: Mutex<bool>,
    published: Mutex<Vec<Event>>,
}

impl FakePublisher {
    const fn new(ack: bool) -> Self {
        Self {
            ack: Mutex::new(ack),
            published: Mutex::new(Vec::new()),
        }
    }

    fn published(&self) -> Vec<Event> {
        self.published.lock().unwrap().clone()
    }

    fn set_ack(&self, ack: bool) {
        *self.ack.lock().unwrap() = ack;
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
            *self.ack.lock().unwrap()
        })
    }
}

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
    let group_relays = vec!["wss://group.example.com".to_string()];
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let (bob, bob_keys, bob_member, bob_dir) = mint_member(&inbox).await;
    let (carol, carol_keys, carol_member, carol_dir) = mint_member(&inbox).await;

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let config = CircleConfig::new("OD4-c Circle").with_relays(group_relays.clone());
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

    Fixture {
        alice,
        alice_dir,
        alice_keys,
        bob,
        bob_keys,
        carol,
        mls_group_id,
        nostr_group_id,
        _dirs: vec![bob_dir, carol_dir],
    }
}

/// Drains `circle`'s convergence until its jitter-delayed `SelfRemove`
/// auto-commit surfaces, returning the raw publish item — the wrapped commit and
/// its pending ref, exactly as a receive plane is handed it.
///
/// The engine re-queues the group until the wall-clock due time passes, so a
/// single advance would drain it out of the pending set and strand the eviction.
async fn stage_eviction_work(
    circle: &CircleManager,
    group_id: &GroupId,
) -> (TransportMessage, PendingStateRef) {
    for _ in 0..40 {
        let effects = circle
            .session()
            .advance_convergence(group_id)
            .await
            .expect("advance convergence");
        if let Some((msg, pending)) = effects.publish.iter().find_map(|w| match w {
            PublishWork::AutoPublish { msg, pending } => Some((msg.clone(), *pending)),
            _ => None,
        }) {
            return (msg, pending);
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("the SelfRemove auto-commit never surfaced within the jitter window");
}

/// [`stage_eviction_work`] as the signed `kind:445` a publisher would send.
async fn stage_eviction(circle: &CircleManager, group_id: &GroupId) -> (Event, PendingStateRef) {
    let (msg, pending) = stage_eviction_work(circle, group_id).await;
    let event = SessionManager::transport_message_to_event(&msg).expect("commit event");
    (event, pending)
}

/// Bob's eviction genuinely STAGED on Alice's side and unresolved, exactly as a
/// receive plane is handed it — plus the epoch the group returns to if it is
/// ever rolled back.
///
/// `epoch_before` is captured BEFORE the proposal on purpose. A staged commit is
/// already reflected in what the session projects: between surfacing and
/// resolution `member_pubkeys` omits the leaver and `epoch` reads one higher, and
/// only the resolution decides whether that view becomes real or is reverted. So
/// the pre-proposal epoch is the baseline a rollback lands on, and the staged
/// view is `epoch_before + 1`.
struct ArmedEviction {
    fx: Fixture,
    msg: TransportMessage,
    pending: PendingStateRef,
    epoch_before: u64,
}

async fn arm_eviction() -> ArmedEviction {
    let fx = build_fixture().await;
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
        .expect("alice ingests the proposal");
    let (msg, pending) = stage_eviction_work(&fx.alice, &fx.mls_group_id).await;
    ArmedEviction {
        fx,
        msg,
        pending,
        epoch_before,
    }
}

impl Fixture {
    /// Models the process dying: drops every live handle on Alice's store and
    /// hands back what is needed to reopen it.
    ///
    /// The temp dir is MOVED out rather than borrowed, because dropping the
    /// fixture would delete the directory and the "reborn" session would then
    /// open a FRESH empty database — which passes an "is the deferral gone?"
    /// assertion for entirely the wrong reason. The caller must drop any
    /// `EngineProcessor` first: the last `Arc<CircleManager>` has to go with this
    /// call, or the reopen would be a second live session on one DB file
    /// (Rule 14).
    fn kill_process(self) -> (TempDir, Keys) {
        (self.alice_dir, self.alice_keys)
    }
}

async fn roster(circle: &CircleManager, group_id: &GroupId) -> Vec<String> {
    circle.session().member_pubkeys(group_id).await.unwrap()
}

async fn epoch(circle: &CircleManager, group_id: &GroupId) -> u64 {
    circle.session().epoch(group_id).await.unwrap()
}

/// Feeds Bob's `SelfRemove` proposal through the processor and re-ticks it with
/// distinct peer locations until the jitter-delayed auto-commit has surfaced.
///
/// Re-ticking with a FRESH peer event each round is how the real loop reaches the
/// auto-commit: the engine re-queues the group until the wall-clock due time
/// passes, and each ingest drives `advance_convergence`.
async fn feed_leave_through(processor: &EngineProcessor, fx: &Fixture) -> Event {
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    processor
        .process_group_event(&proposal, &fx.nostr_group_id)
        .await;
    let carol_pk = fx.carol.session().identity_pubkey();
    for i in 0..40 {
        // A deferral or a publish is what ends this loop; both are observable
        // through the caller's own oracles, so the loop only has to run long
        // enough to cover the ≤50 ms jitter with margin.
        if !fx.alice.owed_removal_commits().is_empty()
            || !roster(&fx.alice, &fx.mls_group_id)
                .await
                .contains(&fx.bob_keys.public_key().to_hex())
        {
            return proposal;
        }
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
    }
    proposal
}

/// Whether the engine will accept an outbound location for `group_id` — i.e.
/// whether the group is back in `Stable` with no commit staged.
///
/// The only observable difference between "the eviction was merged" and "the
/// eviction is still staged": every projected read (`epoch`, `member_pubkeys`,
/// `converged_member_pubkeys`) reports the POST-merge state from the moment the
/// commit is staged, so none of them can tell the two apart. The send gate can.
async fn accepts_a_send(circle: &CircleManager, group_id: &GroupId, keys: &Keys) -> bool {
    circle
        .encrypt_location(
            group_id,
            &keys.public_key(),
            &LocationMessage::new(1.0, 2.0),
            300,
        )
        .await
        .is_ok()
}

// ═══════════════════════════════════════════════════════════════════════════
// (iv) — a background burst never publishes a removal-bearing auto-commit.
// ═══════════════════════════════════════════════════════════════════════════

/// A BACKGROUND burst that ingests a peer `SelfRemove` publishes NOTHING: the
/// eviction commit is parked as a durable per-circle obligation, the group stays
/// where it was, and no publish-before-apply window is opened inside a wake
/// window the OS may end.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_background_burst_does_not_publish_a_removal_bearing_auto_commit() {
    let fx = build_fixture().await;
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);

    let _proposal = feed_leave_through(&processor, &fx).await;

    assert!(
        fake.published().is_empty(),
        "a background burst must put NO removal-bearing commit on the wire: \
         hydrate does not recover one that is cut between SEND and OK"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "the obligation must be recorded DURABLY, so it outlives the process"
    );
    assert!(
        !accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
        "the commit is STAGED and unresolved, so the group is not Stable — this \
         is what distinguishes a parked commit from a merged one, since every \
         projected read already shows the post-merge roster"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "the projected epoch of the staged commit: the deferral changes what is \
         PUBLISHED, not what the engine staged"
    );
}

/// The deferral closes the SEND route too, and that is not a side effect — it is
/// what makes (iv) complete.
///
/// The engine stages a due `SelfRemove` auto-commit from the SEND path as well
/// (`should_queue_outbound_intent` calls `stage_due_self_remove_auto_commit`), so
/// a burst that merely declined to publish what its convergence drain surfaced
/// would have the next background location publish stage and hand back the same
/// commit — the identical window, one tick later. Parking the commit prevents
/// that structurally: the group stays in `PendingPublish`, and that check is the
/// FIRST thing `should_queue_outbound_intent` does, so no background send can
/// reach the staging code at all.
///
/// The cost is real and bounded: that one circle's location publishes fail until
/// the foreground redemption. It fails as the engine's existing typed
/// "not Stable" refusal, not silently.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_background_send_can_stage_a_second_removal_commit() {
    let fx = build_fixture().await;
    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    feed_leave_through(&processor, &fx).await;
    assert_eq!(fx.alice.owed_removal_commits(), vec![fx.nostr_group_id]);

    // Every background publish tick for this circle, for as long as the deferral
    // stands.
    for _ in 0..3 {
        assert!(
            !accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
            "the send is refused while the eviction is parked"
        );
    }
    assert!(
        fake.published().is_empty(),
        "and NOTHING reached the wire: the send route cannot stage — let alone \
         publish — a removal-bearing commit while one is parked"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "exactly one obligation, not one per refused send"
    );
}

/// The same input through a FOREGROUND session publishes and confirms exactly as
/// before. The suppression is scoped to background bursts and nothing else.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_foreground_session_publishes_the_same_removal_commit() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    // No `set_background_burst` call: a fresh processor defaults to the FOREGROUND
    // lifecycle, and the publish below is what proves that default.
    let _proposal = feed_leave_through(&processor, &fx).await;

    assert_eq!(
        fake.published().len(),
        1,
        "a foreground session must still publish the eviction commit"
    );
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "and evict the leaver once a relay acked it"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "the epoch advances past the confirmed eviction"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "a foreground publish owes nothing afterwards"
    );
}

/// The deferred removal LANDS: the next foreground pass publishes the parked
/// commit, confirms it on the ack, evicts the leaver and clears the obligation.
///
/// This is the test that fails if a deferral is ever left un-redeemed — the
/// silent-drop failure the whole design exists to avoid.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deferred_removal_is_published_by_the_next_foreground_pass() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let epoch_before = epoch(&fx.alice, &fx.mls_group_id).await;

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    let _proposal = feed_leave_through(&processor, &fx).await;
    assert!(fake.published().is_empty(), "parked, not published");

    // The foreground pass.
    processor.set_background_burst(false);
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();

    assert_eq!(
        fake.published().len(),
        1,
        "the foreground pass must publish the commit the burst parked"
    );
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the departing peer is finally evicted — a deferred removal that never \
         lands is a privacy regression, not a delay"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "confirmed, so the epoch move is real"
    );
    assert!(
        accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
        "the group is Stable again — the staged commit was MERGED, not merely \
         projected"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and nothing is owed once it is confirmed"
    );
}

/// A redemption no relay acks keeps the obligation: never confirmed (Rule 13),
/// and never rolled back either, because a rollback is the permanent silent drop
/// this module's docs record. The NEXT foreground pass lands it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_disposition_here_ever_drops_the_removal() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    let _proposal = feed_leave_through(&processor, &fx).await;

    // Foreground, but every relay drops the publish.
    fake.set_ack(false);
    processor.set_background_burst(false);
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();

    assert_eq!(fake.published().len(), 1, "a publish IS attempted");
    assert!(
        !accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
        "no ack, so the commit is still staged and unconfirmed (Rule 13)"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "the obligation SURVIVES a failed publish: rolling it back would drop \
         the removal permanently and silently"
    );

    // A later pass with a relay that acks lands it.
    fake.set_ack(true);
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the retried redemption evicts the leaver"
    );
    assert!(fx.alice.owed_removal_commits().is_empty(),);
}

/// While a deferral stands, a remaining peer's competing eviction commit is
/// BUFFERED, not applied — so it cannot discharge the obligation in this session.
///
/// This is not a defect and it is not a choice Haven makes: the group is in
/// `PendingPublish` (the deferred commit is staged), and the engine buffers every
/// inbound commit until that resolves. It is pinned here because the deferral's
/// whole safety argument rests on it: the parked commit is the ONLY thing that
/// can move this circle forward until a foreground pass publishes it, which is
/// exactly why the obligation may never be dropped.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peer_eviction_arriving_while_the_deferral_stands_is_buffered() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::with_publisher(Arc::clone(&fx.alice), bus, publisher);
    processor.set_background_burst(true);
    let proposal = feed_leave_through(&processor, &fx).await;
    assert_eq!(fx.alice.owed_removal_commits(), vec![fx.nostr_group_id]);

    // Carol, the OTHER remaining member, commits Bob's SelfRemove and publishes
    // it. Alice ingests that commit while her own is parked.
    fx.carol
        .session()
        .process_event(&proposal)
        .await
        .expect("carol ingests the proposal");
    let (carol_commit_event, carol_pending) = stage_eviction(&fx.carol, &fx.mls_group_id).await;
    fx.carol
        .confirm_published(carol_pending)
        .await
        .expect("carol confirms after her own publish");

    let outcome = processor
        .process_group_event(&carol_commit_event, &fx.nostr_group_id)
        .await;
    assert_eq!(
        outcome,
        haven_core::relay::live_sync::GroupProcessOutcome::Buffered,
        "a group with a staged commit buffers every inbound commit"
    );
    // `Buffered` is the engine's "I cannot apply this yet" — Rule 12's legitimate
    // backlog verdict. It must never present as the terminal per-circle verdict.
    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty(),
        "a Buffered input is backlog, not a wedge: reporting it would call every \
         circle mid-handshake unrecoverable"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "so the obligation still stands — dropping it here would leave the \
         circle with nothing that can move it forward"
    );

    // The foreground redemption is what actually resolves it, and then the
    // buffered peer commit converges behind it.
    processor.set_background_burst(false);
    processor.redeem_removal_deferrals().await;
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the leaver is evicted"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and the obligation is discharged"
    );
}

/// An orphaned deferral whose circle a PEER healed after the restart is NOT
/// reported.
///
/// This is the false positive the verdict must never produce — telling a user to
/// re-create a circle that works. What prevents it is NOT an epoch move: applying
/// the peer's commit of the same `SelfRemove` emits no `EpochChanged` at all,
/// because the group record's epoch was already projected forward when our own
/// commit was staged. The next successful SEND is the clear, and it is positive
/// proof — the engine accepts an outbound message only from `Stable`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deferral_a_peer_healed_after_a_restart_is_not_reported() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let nostr_group_id = fx.nostr_group_id;
    let mls_group_id = fx.mls_group_id.clone();

    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    let proposal = feed_leave_through(&processor, &fx).await;

    // Carol commits the same eviction and confirms it.
    fx.carol
        .session()
        .process_event(&proposal)
        .await
        .expect("carol ingests the proposal");
    let (carol_commit_event, carol_pending) = stage_eviction(&fx.carol, &fx.mls_group_id).await;
    fx.carol
        .confirm_published(carol_pending)
        .await
        .expect("carol confirms");

    // Alice's process dies with the deferral parked.
    drop(processor);
    let (alice_dir, alice_keys) = fx.kill_process();
    let reborn = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    assert_eq!(
        reborn.orphaned_removal_deferrals(),
        vec![nostr_group_id],
        "the row outlived the session, as it must"
    );

    // The new session receives Carol's eviction commit — the heal — BEFORE it
    // re-anchors in the foreground.
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let next_session = EngineProcessor::with_publisher(Arc::clone(&reborn), bus, publisher);
    next_session
        .process_group_event(&carol_commit_event, &nostr_group_id)
        .await;
    // The heal leaves NO engine event to clear the row on (the record's epoch was
    // already projected forward when the commit was staged, so the engine reports
    // `Processed` with an empty event batch) — which is why the `EpochChanged`
    // fold is not the mechanism here. What clears it is the next successful
    // publish, which is positive proof the group is `Stable`.
    assert!(
        accepts_a_send(&reborn, &mls_group_id, &alice_keys).await,
        "the healed circle accepts a send again"
    );
    next_session.redeem_removal_deferrals().await;
    next_session.report_unrecoverable_circles();

    assert!(
        !roster(&reborn, &mls_group_id).await.contains(&bob_hex),
        "the peer's commit healed the circle"
    );
    assert!(
        reborn.owed_removal_commits().is_empty(),
        "so the obligation is discharged by the successful send above"
    );
    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty(),
        "and a healed circle must NEVER be reported unrecoverable — that would \
         tell the user to re-create a circle that works"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// (i) — the wedge that survives (iv) is reported, and nothing else is.
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

/// A deferral that outlived the session which staged it reports the circle
/// UNRECOVERABLE, naming it by `nostr_group_id`.
///
/// The process death is modelled the way it happens: the durable row survives,
/// the in-memory `PendingStateRef` does not, and at the pinned MDK rev nothing
/// can re-derive the eviction from group state.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deferral_that_outlived_its_session_reports_the_circle_unrecoverable() {
    let fx = build_fixture().await;

    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    let _proposal = feed_leave_through(&processor, &fx).await;
    assert!(!fx.alice.owed_removal_commits().is_empty());

    // The process dies: drop every handle on the store, then reopen it.
    let nostr_group_id = fx.nostr_group_id;
    drop(processor);
    let (alice_dir, alice_keys) = fx.kill_process();
    let reborn = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    assert_eq!(
        reborn.orphaned_removal_deferrals(),
        vec![nostr_group_id],
        "a durable row with no live deferral is the wedge, and the only signal \
         there is that it happened"
    );

    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let next_session = EngineProcessor::with_publisher(reborn, bus, publisher);
    next_session.redeem_removal_deferrals().await;
    next_session.report_unrecoverable_circles();

    assert_eq!(
        unrecoverable_ids(&drain(&mut rx)),
        vec![nostr_group_id.to_vec()],
        "the terminal verdict must be emitted, naming the circle"
    );
}

/// The verdict carries the pseudonymous `nostr_group_id` and NOTHING that could
/// identify the MLS group (Security Rule 4), and its `Debug` prints neither.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_verdict_carries_the_nostr_group_id_and_never_the_mls_group_id() {
    let fx = build_fixture().await;
    let mls_group_id = fx.mls_group_id.as_slice().to_vec();
    let nostr_group_id = fx.nostr_group_id;
    assert_ne!(
        mls_group_id,
        nostr_group_id.to_vec(),
        "the fixture must have two distinct ids for this assertion to mean anything"
    );

    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    let _proposal = feed_leave_through(&processor, &fx).await;
    drop(processor);
    let (alice_dir, alice_keys) = fx.kill_process();

    let reborn = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let next_session = EngineProcessor::with_publisher(reborn, bus, publisher);
    next_session.redeem_removal_deferrals().await;
    next_session.report_unrecoverable_circles();

    let events = drain(&mut rx);
    let ids = unrecoverable_ids(&events);
    assert_eq!(ids, vec![nostr_group_id.to_vec()]);
    for ev in &events {
        let rendered = format!("{ev:?}");
        assert!(
            !rendered.contains(&hex::encode(&mls_group_id)),
            "leaked the MLS group id: {rendered}"
        );
        assert!(
            !rendered.contains(&hex::encode(nostr_group_id)),
            "even the pseudonymous id must not render in Debug: {rendered}"
        );
    }
}

/// A circle whose parked commit this session CAN still redeem is never reported:
/// it is awaiting an ack, which is a transient state, not a wedge.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_awaiting_its_own_ack_is_not_reported_unrecoverable() {
    let fx = build_fixture().await;
    let fake = Arc::new(FakePublisher::new(false)); // no relay acks: still owed
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::with_publisher(Arc::clone(&fx.alice), bus, publisher);
    processor.set_background_burst(true);
    let _proposal = feed_leave_through(&processor, &fx).await;

    processor.set_background_burst(false);
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();

    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "still owed"
    );
    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty(),
        "a deferral THIS session can retry is not a wedge — reporting it would \
         tell the user to re-create a circle that is about to heal itself"
    );
}

/// A paused engine reports nothing. A pause is a state, not a fault: it holds no
/// REQ and no socket, and it publishes nothing by design.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_paused_engine_reports_no_circle_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let processor = EngineProcessor::with_publisher(Arc::clone(&fx.alice), bus, publisher);
    // The pause's own signal, on a circle with nothing owed.
    processor.set_background_burst(true);
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();

    let events = drain(&mut rx);
    assert!(
        unrecoverable_ids(&events).is_empty(),
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

/// A relay outage reports nothing: no relay acked, so nothing was owed and
/// nothing is terminal. The circle recovers when a relay comes back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_outage_reports_no_circle_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    // Every publish fails, as under an outage.
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(false));
    let processor = EngineProcessor::with_publisher(Arc::clone(&fx.alice), bus, publisher);
    let _proposal = feed_leave_through(&processor, &fx).await;
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();

    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty(),
        "an outage is not a wedge: the same commit is retried next pass"
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
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let processor = EngineProcessor::with_publisher(Arc::clone(&fx.alice), bus, publisher);

    // Carol removes nobody but MOVES her epoch by leaving-and-committing is not
    // available to her, so instead: Bob leaves, CAROL commits the eviction and
    // confirms it, and Carol then encrypts a location at her NEW epoch. Alice
    // never sees the commit, so that location is a future-epoch input.
    let proposal = fx.bob.propose_leave(&fx.mls_group_id).await.unwrap();
    fx.carol
        .session()
        .process_event(&proposal)
        .await
        .expect("carol ingests the proposal");
    let (_carol_commit, carol_pending) = stage_eviction(&fx.carol, &fx.mls_group_id).await;
    fx.carol.confirm_published(carol_pending).await.unwrap();
    let carol_pk = fx.carol.session().identity_pubkey();
    let (future_loc, _, _) = fx
        .carol
        .encrypt_location(
            &fx.mls_group_id,
            &carol_pk,
            &LocationMessage::new(3.0, 4.0),
            300,
        )
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
    processor.redeem_removal_deferrals().await;
    processor.report_unrecoverable_circles();

    assert!(
        unrecoverable_ids(&drain(&mut rx)).is_empty(),
        "a future-epoch input is backlog convergence drains, never a terminal \
         verdict (Rule 12)"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and it owes no removal commit"
    );
}

/// A message that could not be applied reports nothing terminal: it is a
/// per-EVENT, self-clearing signal that names no circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unprocessable_event_reports_no_circle_unrecoverable() {
    let fx = build_fixture().await;
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let processor = EngineProcessor::with_publisher(Arc::clone(&fx.alice), bus, publisher);

    // A kind-445 for this circle whose ciphertext the engine cannot peel.
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

    let events = drain(&mut rx);
    assert!(
        unrecoverable_ids(&events).is_empty(),
        "one unreadable event must never present as a terminal circle verdict"
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

/// The ENGINE fact that makes every disposition above the only safe one, pinned
/// against the pinned MDK rev rather than against a Haven plane: rolling a
/// receive-side auto-commit back drops the removal AND leaves the circle unable
/// to send.
///
/// Driven through `SessionManager::publish_failed` — the raw engine call, BELOW
/// Haven's planes — because no Haven plane can reach this any more
/// (`CircleManager::publish_failed` keeps such a commit owed). Testing it here is
/// what keeps the reason honest: the two harms are properties of MDK `e391adc`,
/// not of Haven's bookkeeping, and neither is visible from the engine's read
/// accessors — which is exactly why a reader reaching for `publish_failed` would
/// think it cheap:
///
/// * the leaver is BACK in the roster and no later ingest re-derives the
///   eviction (the in-memory `SelfRemove` auto-commit schedule was dropped
///   before staging, `do_publish_failed` does not re-arm it, and a redelivered
///   proposal short-circuits to `Buffered` off its durable `Created` row);
/// * `do_publish_failed` clears the staged COMMIT but not the stored PROPOSAL,
///   and `OpenMLS`'s `create_message` refuses while the proposal store is
///   non-empty — so every later `encrypt_location` for that circle fails until
///   some commit merges and empties it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rolled_back_removal_commit_drops_the_removal_and_wedges_the_circle() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
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
        fx.alice.owed_removal_commits().is_empty(),
        "a rollback records NO obligation — which is why the wedge it leaves is \
         invisible to the OD4-c detector, and why no Haven plane may choose it"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the leaver is back in the circle: the removal was DROPPED, and the \
         projected post-eviction roster rolled back with the staged commit"
    );
    assert!(
        !accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
        "and the circle cannot send either: the stored SelfRemove proposal \
         outlives the cleared commit, so `create_message` refuses"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Every OTHER plane: the same guarantee, and the record that makes it visible.
// ═══════════════════════════════════════════════════════════════════════════

/// Surfaces the eviction commit the way the two DART planes get it: through
/// `decrypt_location_collecting_commits`, which is the Rust half of both the
/// foreground poll path (`resolveAutoCommits`) and the Android foreground
/// service's publish cycle.
///
/// Re-ticked with a fresh peer location each round because the engine schedules
/// the auto-commit with a wall-clock jitter and re-queues the group until it is
/// due; the loop ends on the OBSERVABLE (a commit surfaced), never on a duration.
async fn surface_through_decrypt(fx: &Fixture) -> haven_core::circle::CommitToPublish {
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    let mut ingest = fx
        .alice
        .decrypt_location_collecting_commits(&proposal)
        .await
        .expect("alice ingests the proposal");
    let carol_pk = fx.carol.session().identity_pubkey();
    for i in 0..40 {
        if let Some(commit) = ingest.auto_commits.pop() {
            return commit;
        }
        let (loc_event, _, _) = fx
            .carol
            .encrypt_location(
                &fx.mls_group_id,
                &carol_pk,
                &LocationMessage::new(f64::from(i).mul_add(0.01, 5.0), 6.0),
                300,
            )
            .await
            .expect("carol encrypts a re-tick location");
        ingest = fx
            .alice
            .decrypt_location_collecting_commits(&loc_event)
            .await
            .expect("alice re-ticks convergence");
    }
    panic!("the SelfRemove auto-commit never surfaced to the caller");
}

/// The FFI rung both Dart planes call on a no-ack — `publishFailed` /
/// `failPendingCommit`, i.e. [`CircleManager::publish_failed`] — does NOT roll a
/// removal-bearing commit back. It leaves it owed, and a foreground pass lands it.
///
/// This is the hole that made the detector blind to three planes: each of them
/// published from a background wake window and, on no ack, discarded the removal
/// with nothing recorded anywhere. Neither Dart plane needs to know — the
/// guarantee lives at the one rung all of them go through, so it also covers a
/// plane written after this test.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_ffi_fail_rung_keeps_a_removal_owed_instead_of_rolling_it_back() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let commit = surface_through_decrypt(&fx).await;
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "the obligation is recorded BEFORE the commit crosses the FFI, so a Dart \
         isolate killed mid-publish leaves a detectable row"
    );

    // The Dart plane's publish found no relay that acked.
    fx.alice
        .publish_failed(commit.pending)
        .await
        .expect("the fail rung is not an error");

    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the eviction was NOT discarded: a rollback would put the leaver back in \
         the circle, still able to derive its keys, with nothing able to re-derive \
         the commit"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "and the obligation still stands"
    );
    assert!(
        !accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
        "the commit is still STAGED — this is `PendingPublish`, which a later \
         publish can resolve, not the `PendingProposal` dead end a rollback leaves"
    );

    // A foreground pass redeems what the Dart plane could not publish.
    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.redeem_removal_deferrals().await;

    assert_eq!(
        fake.published().len(),
        1,
        "the foreground pass publishes it"
    );
    assert!(
        accepts_a_send(&fx.alice, &fx.mls_group_id, &fx.alice_keys).await,
        "the commit MERGED, so the circle sends again"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and the obligation is discharged"
    );
}

/// A plane that dies between handing the commit over and resolving it leaves the
/// wedge DETECTABLE. That is what recording the obligation write-ahead buys.
///
/// Before this, only a background burst's park wrote the durable row, so a
/// foreground-poll or foreground-service publish cut mid-flight left a staged
/// removal-bearing commit MDK's hydrate will not clear, no
/// `PendingCommitRecovered`, and no row — a circle that silently stopped sending
/// with nothing anywhere saying why.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plane_killed_mid_publish_leaves_a_detectable_wedge() {
    let fx = build_fixture().await;
    let nostr_group_id = fx.nostr_group_id;
    let commit = surface_through_decrypt(&fx).await;
    // The process dies here: the commit was handed over and neither confirmed nor
    // reported failed.
    drop(commit);
    let (alice_dir, alice_keys) = fx.kill_process();

    let reborn = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    assert_eq!(
        reborn.orphaned_removal_deferrals(),
        vec![nostr_group_id],
        "the row outlived the session that took the obligation, and its \
         `PendingStateRef` did not — which is exactly the wedge"
    );

    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let publisher: Arc<dyn AutoCommitPublisher> = Arc::new(FakePublisher::new(true));
    let next_session = EngineProcessor::with_publisher(reborn, bus, publisher);
    next_session.redeem_removal_deferrals().await;
    next_session.report_unrecoverable_circles();

    assert_eq!(
        unrecoverable_ids(&drain(&mut rx)),
        vec![nostr_group_id.to_vec()],
        "and it is REPORTED, naming the circle by its pseudonymous id"
    );
}

/// A background burst never publishes an obligation that is ALREADY owed, however
/// many events it processes afterwards.
///
/// The redemption is a foreground act by construction — the session gates the call
/// on its own typed `BurstKind`, and `start` is gated out by a source rule — but a
/// burst that kept ingesting could otherwise reach the publisher through its own
/// receive path. It does not: the parked commit pins the group in
/// `PendingPublish`, and nothing in a burst opens the window the deferral exists
/// to avoid.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_background_burst_never_publishes_an_obligation_already_owed() {
    let fx = build_fixture().await;
    let fake = Arc::new(FakePublisher::new(true));
    let publisher: Arc<dyn AutoCommitPublisher> = fake.clone();
    let processor =
        EngineProcessor::with_publisher(Arc::clone(&fx.alice), EventBus::new(), publisher);
    processor.set_background_burst(true);
    feed_leave_through(&processor, &fx).await;
    assert_eq!(fx.alice.owed_removal_commits(), vec![fx.nostr_group_id]);

    // Ten more burst-delivered events, from the one peer that can still encrypt.
    let carol_pk = fx.carol.session().identity_pubkey();
    for i in 0..10 {
        let (loc_event, _, _) = fx
            .carol
            .encrypt_location(
                &fx.mls_group_id,
                &carol_pk,
                &LocationMessage::new(f64::from(i).mul_add(0.01, 7.0), 8.0),
                300,
            )
            .await
            .expect("carol encrypts");
        processor
            .process_group_event(&loc_event, &fx.nostr_group_id)
            .await;
    }

    assert!(
        fake.published().is_empty(),
        "no burst may put a removal-bearing commit on the wire, including one it \
         already owes"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "and the obligation is neither discharged nor duplicated"
    );
}

/// The PUBLISHING planes (the background catch-up sweep and a foreground live-sync
/// open) record the obligation BEFORE the publish, not after it fails.
///
/// The ordering is the whole point. A wake window the OS ends between SEND and OK
/// leaves a staged removal-bearing commit MDK's hydrate refuses to clear; only a
/// row written before the send survives to say so. The observation is taken from
/// inside the publisher, which is the only place that can see "the row exists and
/// the event is on its way".
/// Reports what the device OWED at the instant each event went to the relay
/// plane — the only vantage point from which "the row exists and the commit is on
/// the wire" is observable at once.
struct OwedAtPublish {
    circle: Arc<CircleManager>,
    owed: Mutex<Vec<Vec<[u8; 32]>>>,
    ack: bool,
}

impl AutoCommitPublisher for OwedAtPublish {
    fn publish_auto_commit<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.owed
                .lock()
                .unwrap()
                .push(self.circle.owed_removal_commits());
            self.ack
        })
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_publishing_plane_records_its_obligation_before_it_publishes() {
    let ArmedEviction {
        fx, msg, pending, ..
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let observer = Arc::new(OwedAtPublish {
        circle: Arc::clone(&fx.alice),
        owed: Mutex::new(Vec::new()),
        ack: false, // the wake window's relays never answered
    });
    let publisher: Arc<dyn AutoCommitPublisher> = observer.clone();
    resolve_receive_publish_work(
        &fx.alice,
        publisher.as_ref(),
        &[PublishWork::AutoPublish { msg, pending }],
    )
    .await;

    assert_eq!(
        observer.owed.lock().unwrap().as_slice(),
        [vec![fx.nostr_group_id]],
        "the durable row must already exist while the commit is on the wire — a \
         row written only after a failed publish records nothing about a process \
         the OS killed mid-publish"
    );
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "and the no-ack keeps the eviction rather than discarding it"
    );
    assert_eq!(fx.alice.owed_removal_commits(), vec![fx.nostr_group_id]);
}

/// The Android foreground service's DEFERRED-SEND plane owes its eviction before
/// the commit crosses the FFI, and its no-ack keeps it owed.
///
/// That plane reaches the commit from the SEND side: `encrypt_location` finds the
/// peer's `SelfRemove` due, stages the eviction inside the call, and hands it back
/// on `CircleError::SendDeferred` for Dart to publish. It is the third plane the
/// detector used to be blind to.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_deferred_send_plane_owes_its_eviction_before_it_crosses_the_ffi() {
    let fx = build_fixture().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    fx.alice
        .session()
        .process_event(&proposal)
        .await
        .expect("alice ingests the proposal");

    // The publish cycle retries until the engine reports the deferral carrying the
    // staged commit: the auto-commit's due time is the engine's own wall clock, so
    // the loop ends on the OBSERVABLE outcome and never on a duration.
    let mut commits = Vec::new();
    for _ in 0..40 {
        match fx
            .alice
            .encrypt_location(
                &fx.mls_group_id,
                &fx.alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
            .await
        {
            Err(haven_core::circle::CircleError::SendDeferred { work, .. })
                if !work.commits.is_empty() =>
            {
                commits = work.commits;
                break;
            }
            _ => tokio::time::sleep(Duration::from_millis(25)).await,
        }
    }
    assert_eq!(
        commits.len(),
        1,
        "the deferred send must hand back the staged eviction commit"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "recorded before it crossed the FFI, so an isolate killed mid-publish \
         leaves the wedge detectable"
    );

    // The foreground service published it and no relay acked.
    fx.alice
        .publish_failed(commits[0].pending)
        .await
        .expect("the fail rung is not an error");

    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the eviction survives the failed publish"
    );
    assert_eq!(
        fx.alice.owed_removal_commits(),
        vec![fx.nostr_group_id],
        "and stays owed for the next foreground pass"
    );
}

// ── When the obligation itself cannot be recorded ────────────────────────────
//
// `owe_removal_publish` keys its durable row by `nostr_group_id` and refuses a
// group this device holds no circle row for, so every plane below has a rung for
// "the debt could not be written down". That rung is reachable in production: a
// leave finalized — or a circle deleted — while a receive batch is in flight
// removes the row from under a commit the engine has already staged. Two of
// those rungs have a WARNING as their only observable effect, and a residual
// nobody is told about is the wedge OD4-c exists to end.

/// A fixed wall clock for the local leave in these tests: `complete_leave`
/// computes a directory retention deadline from it, so it is pinned to a value
/// rather than to when the test happens to run.
const LEAVE_AT_UNIX_SECS: i64 = 1_800_000_000;

/// The identifiers in hand at the moment either warning fires. Neither may name
/// the group, the leaver or the circle it is about (Security Rule 15): these
/// lines are the ONE place a group identifier is already in scope, so a "more
/// helpful" interpolation is exactly the regression to expect.
fn eviction_needles(fx: &Fixture) -> Vec<String> {
    vec![
        hex::encode(fx.nostr_group_id),
        hex::encode(fx.mls_group_id.as_slice()),
        fx.bob_keys.public_key().to_hex(),
        fx.alice_keys.public_key().to_hex(),
        "OD4-c Circle".to_owned(),
    ]
}

/// The publishing planes SAY SO when the obligation cannot be recorded — and
/// that is the one shape in which their fail rung still drops the eviction.
///
/// Reachable, not hypothetical: the row is keyed by `nostr_group_id` and the
/// relays are resolved from the same circle row, so a leave finalized while a
/// receive batch is in flight leaves the plane holding a staged eviction with
/// nowhere to publish it and nothing to record it against. Nothing is owed, so
/// [`CircleManager::publish_failed`]'s refusal to roll a removal back does not
/// apply and the eviction goes. The warning is what makes that residual visible
/// instead of silent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_publish_with_no_recordable_obligation_says_so_and_can_still_drop_it() {
    let ArmedEviction {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    // The row goes while the eviction is STAGED: the engine still holds the
    // group, so the commit is live and no longer resolvable against any circle.
    fx.alice
        .complete_leave(&fx.mls_group_id, LEAVE_AT_UNIX_SECS)
        .await
        .expect("the local circle row is removed");

    let publisher = FakePublisher::new(true);
    let lines = capture_haven_log(async {
        resolve_receive_publish_work(
            &fx.alice,
            &publisher,
            &[PublishWork::AutoPublish { msg, pending }],
        )
        .await;
    })
    .await;

    let warning = lines
        .iter()
        .find(|line| line.message.contains("no recorded obligation"))
        .expect(
            "a plane that opens a publish-before-apply window with nothing \
             recording the debt must say so: the durable row is what turns this \
             wedge from silent into reportable, and this is the case where there \
             is none",
        );
    let needles = eviction_needles(&fx);
    assert_no_needles(
        std::slice::from_ref(warning),
        &needles.iter().map(String::as_str).collect::<Vec<_>>(),
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "premise: the obligation really could not be recorded"
    );
    assert!(
        publisher.published().is_empty(),
        "and there is nowhere to publish it either — the relays come from the same \
         row that is gone, so the ladder fails closed without touching the \
         transport"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "so the fail rung discards the eviction: the residual the warning names, \
         and the reason the record is attempted BEFORE the publish rather than \
         after it fails"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "the staged commit is gone, not merely unpublished"
    );
}

/// A plane with NO relay handle that cannot even park says so — and leaves the
/// commit STAGED rather than discarding it.
///
/// Staged is the lesser evil of the two: this device's projected roster keeps the
/// leaver out either way, and only a rollback puts them back with no path left to
/// evict them. The circle cannot send until the wedge is resolved, which is
/// exactly what the warning is for.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_park_that_cannot_be_recorded_says_so_and_leaves_the_commit_staged() {
    let ArmedEviction {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    fx.alice
        .complete_leave(&fx.mls_group_id, LEAVE_AT_UNIX_SECS)
        .await
        .expect("the local circle row is removed");

    let lines = capture_haven_log(async {
        park_or_rollback_receive_publish_work(
            &fx.alice,
            &[PublishWork::AutoPublish { msg, pending }],
        )
        .await;
    })
    .await;

    let warning = lines
        .iter()
        .find(|line| line.message.contains("left staged"))
        .expect(
            "a commit left staged with no obligation behind it is the silent \
             wedge OD4-c exists to end, so the one plane that can produce it \
             must report it",
        );
    let needles = eviction_needles(&fx);
    assert_no_needles(
        std::slice::from_ref(warning),
        &needles.iter().map(String::as_str).collect::<Vec<_>>(),
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "premise: the park really could not be recorded"
    );
    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "and it is still not rolled back: a rollback is the permanent silent drop \
         of the removal, which no plane here takes even when it cannot record the \
         debt"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "the staged commit's projected epoch — nothing applied, nothing reverted"
    );

    // Only a ref the engine still holds can be rolled back, so the revert is the
    // proof that the commit was LEFT STAGED rather than quietly resolved.
    // Deliberately the raw engine call: Haven's own planes keep such a commit
    // owed, which would prove nothing about whether the ref was still live.
    fx.alice
        .session()
        .publish_failed(pending)
        .await
        .expect("the staged ref must still be resolvable");
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "proof the park left the pending ref alone: only a live ref can revert"
    );
}

/// The one staged eviction a plane with no relay handle still rolls back: a
/// commit whose wrapped transport message will not serialize.
///
/// There is then no event to owe a publish for and nothing to broadcast, and
/// leaving it staged would freeze the circle's sends with no obligation recorded
/// — a wedge with no report and no handle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plane_with_no_relay_handle_rolls_back_a_commit_it_cannot_serialize() {
    let ArmedEviction {
        fx,
        mut msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    // The conversion reads `msg.payload` as the transport DTO, so corrupting a
    // REAL staged auto-commit's payload reproduces the branch against a genuine
    // pending ref — which is what makes "the epoch moved back" evidence.
    msg.payload = b"not a transport-wrapped nostr event".to_vec();

    park_or_rollback_receive_publish_work(&fx.alice, &[PublishWork::AutoPublish { msg, pending }])
        .await;

    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "an unserializable commit cannot be parked: there is no event to owe a \
         publish for"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "so this is the one staged eviction still rolled back, rather than left \
         staged with nothing recording the debt"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "and the revert lands back on the pre-proposal epoch"
    );
}

/// A background burst rolls send-side work back instead of parking it.
///
/// The deferral changes what happens to an EVICTION, not to work that has no
/// business on a receive path. `GroupCreated` / `GroupEvolution` originate from
/// `send`, and this device authored them and can re-author them, so a rollback
/// costs a retry — while parking one would owe a publish for a commit
/// [`CircleManager::redeem_removal_deferrals`] is not the resolver of.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_rolls_back_send_side_work_instead_of_parking_it() {
    let ArmedEviction {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    // The resolver decides on the VARIANT alone, so wrapping the genuinely staged
    // commit in a send-side shape is what puts the branch under test — and the
    // ref really is staged, so "nothing moved" is a real observation. The second
    // item's ref is one the engine never issued: both patterns of the arm must be
    // walked, and a ref that resolves to nothing must not stop the loop.
    let publisher = FakePublisher::new(true);
    let deferred = resolve_receive_publish_work_with_policy(
        &fx.alice,
        &publisher,
        &[
            PublishWork::GroupEvolution {
                msg,
                welcomes: vec![],
                pending,
            },
            PublishWork::GroupCreated {
                welcomes: vec![],
                pending: PendingStateRef::new(u64::MAX),
            },
        ],
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;

    assert_eq!(
        deferred, 0,
        "no auto-commit in the batch, so the caller must not be told a removal \
         was parked for the foreground to redeem"
    );
    assert!(
        publisher.published().is_empty(),
        "send-side work on a receive path is a contract violation, not a commit \
         to broadcast"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and no obligation is recorded for a commit that is being rolled back"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "rolled back, never confirmed, even with a relay acking (Rule 13)"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "no epoch may advance on a commit this path never published"
    );
}

/// A burst skips the work that carries no pending ref, and leaves a co-batched
/// staged commit alone.
///
/// "Left alone" needs an observation, not an absence: a staged commit already
/// projects as applied, so it is indistinguishable from a confirmed one. What
/// only a LIVE ref can still do is revert, so the skip is followed by the
/// ENGINE's own rollback and the state reverting is the proof.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_skips_work_that_carries_no_pending_ref() {
    let ArmedEviction {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();

    let publisher = FakePublisher::new(true);
    let deferred = resolve_receive_publish_work_with_policy(
        &fx.alice,
        &publisher,
        &[
            PublishWork::ApplicationMessage { msg: msg.clone() },
            PublishWork::Proposal { msg },
        ],
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;

    assert_eq!(deferred, 0, "neither variant is a removal to park");
    assert!(
        publisher.published().is_empty(),
        "neither is publishable work on this path either"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and a park here would owe a publish nothing can ever discharge"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before + 1,
        "the skip must leave the staged view exactly as it found it"
    );

    fx.alice
        .session()
        .publish_failed(pending)
        .await
        .expect("the skipped ref must still be resolvable");
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "proof the skip consumed nothing: only a ref the engine still holds could \
         have reverted"
    );
}

/// A burst rolls back an auto-commit it cannot serialize, and reports no
/// deferral for it.
///
/// Nothing to publish AND nothing to park: a park needs the event the row is
/// recorded against, so counting this as deferred would promise the foreground a
/// redemption that cannot happen.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_rolls_back_an_auto_commit_it_cannot_serialize() {
    let ArmedEviction {
        fx,
        mut msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    msg.payload = b"not a transport-wrapped nostr event".to_vec();

    let publisher = FakePublisher::new(true);
    let deferred = resolve_receive_publish_work_with_policy(
        &fx.alice,
        &publisher,
        &[PublishWork::AutoPublish { msg, pending }],
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;

    assert_eq!(
        deferred, 0,
        "a commit that cannot be turned into an event was not parked, so the \
         caller must not be told the foreground owes a publish"
    );
    assert!(
        publisher.published().is_empty(),
        "an unconvertible commit must never reach the relay plane"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "and nothing is owed for an event that does not exist"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "so it is rolled back rather than left staged and unrecorded"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "no epoch advance on a commit that was never published"
    );
}

/// A park the device cannot record does not leave a burst silently holding a
/// staged eviction: the item falls through to the Rule-13 ladder.
///
/// An un-recorded deferral is the exact wedge the deferral exists to prevent — a
/// staged removal-bearing commit MDK's hydrate will not clear, with no row to
/// report it — so the fallback is the behaviour that at least tries to land the
/// removal. Here the relays come from the same circle row that could not be
/// recorded against, so the ladder fails closed and the eviction goes: the one
/// residual, and the reason the park is attempted first rather than as a
/// consolation.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_that_cannot_park_falls_through_to_the_publish_ladder() {
    let ArmedEviction {
        fx,
        msg,
        pending,
        epoch_before,
    } = arm_eviction().await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    fx.alice
        .complete_leave(&fx.mls_group_id, LEAVE_AT_UNIX_SECS)
        .await
        .expect("the local circle row is removed");

    let publisher = FakePublisher::new(true);
    let deferred = resolve_receive_publish_work_with_policy(
        &fx.alice,
        &publisher,
        &[PublishWork::AutoPublish { msg, pending }],
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;

    assert_eq!(
        deferred, 0,
        "a park that recorded nothing is not a deferral: reporting one would send \
         the foreground looking for an obligation that does not exist"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "premise: the park really could not be recorded"
    );
    assert!(
        publisher.published().is_empty(),
        "the relays live in the row that is gone, so the ladder's publish rung \
         fails closed without touching the transport"
    );
    assert!(
        roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "so it took the Rule-13 ladder rather than staying staged with nothing \
         recording the debt"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        epoch_before,
        "the fallback resolved the ref: a burst must not end holding an \
         unrecorded staged eviction"
    );
}
