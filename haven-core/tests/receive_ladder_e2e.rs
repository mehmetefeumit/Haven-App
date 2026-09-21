//! One pass over a receive plane must finish the leave cascade it started.
//!
//! Confirming a peer's eviction ends in the engine's replay, which can apply the
//! NEXT leaver's proposal and stage the next eviction. A plane that ran only the
//! batch it was handed would leave that one staged, unpublished and unconfirmed
//! for as long as it takes some other pass to notice — and for the planes that
//! run in a short-lived isolate (the background catch-up sweep, the Android
//! foreground service) there is no other pass: their `PendingStateRef`s die with
//! the isolate, so what they leave behind surfaces as a durable ORPHAN a user is
//! told to rebuild their circle over.
//!
//! So the ladder loops until its worklist is empty, with a resolved-refs set for
//! termination and a cap that is a runaway guard and nothing else. At the cap
//! every un-run commit is PARKED — the same durable row + in-memory ref an
//! ordinary deferral writes — so nothing is rolled back and nothing dangles.
//!
//! # How a cascade is staged here
//!
//! A `SelfRemove` proposal is valid only in its source epoch, so leavers cannot
//! all propose up front: each one has to propose at the epoch the PREVIOUS
//! eviction produced. The recording publisher below is what makes that
//! deterministic — it is a relay, so delivering the commit it was handed to the
//! remaining devices and letting the next leaver propose off the back of it is
//! exactly what a relay does.

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use haven_core::circle::MAX_REDEMPTION_STEPS;
use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::set_stored_message_write_fault_for_test;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult, PublishWork};
use haven_core::nostr::mls::StorageConfig;
use haven_core::relay::auto_commit::{
    resolve_receive_publish_work, resolve_receive_publish_work_with_policy, AutoCommitPublisher,
    ReceiveAutoCommitPolicy, RESOLVE_RUNAWAY_CAP,
};
use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveSyncEvent};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

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
        .create_circle(&alice_keys, key_packages, &config, &relays)
        .await
        .expect("create circle");
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");
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

    /// `leaver` proposes and the OTHER co-members receive it, but Alice does
    /// not — for the caller that wants to feed it to her through a plane.
    async fn mint_leave(&self, leaver: &Device) -> Event {
        let proposal = leaver
            .manager
            .propose_leave(&self.mls_group_id)
            .await
            .expect("the leaver proposes");
        for peer in &self.peers {
            if peer.hex() == leaver.hex() {
                continue;
            }
            let _ = peer.manager.session().process_event(&proposal).await;
        }
        proposal
    }

    /// `leaver` proposes, and everyone who needs the proposal to validate the
    /// commit that will cover it receives one.
    async fn propose_leave(&self, leaver: &Device) -> Event {
        let proposal = leaver
            .manager
            .propose_leave(&self.mls_group_id)
            .await
            .expect("the leaver proposes");
        deliver(&self.alice, &self.peers, leaver, &proposal).await;
        proposal
    }

    /// The raw `AutoPublish` batch the engine stages for the pending
    /// `SelfRemove`, exactly as a receive plane is handed it.
    ///
    /// The engine re-queues the group until a real wall-clock due time passes,
    /// so a single advance would strand the eviction.
    async fn staged_eviction_work(&self) -> Vec<PublishWork> {
        for _ in 0..40 {
            let effects = self
                .alice
                .session()
                .advance_convergence(&self.mls_group_id)
                .await
                .expect("advance convergence");
            if effects
                .publish
                .iter()
                .any(|w| matches!(w, PublishWork::AutoPublish { .. }))
            {
                return effects.publish;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        panic!("the SelfRemove auto-commit never surfaced within the jitter window");
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

/// A recording relay plane with a fixed verdict and no behaviour of its own —
/// for the arms whose subject is the ladder rather than the cascade.
struct FlatPublisher {
    ack: bool,
    published: Mutex<Vec<Event>>,
}

impl FlatPublisher {
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

impl AutoCommitPublisher for FlatPublisher {
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

/// A recording relay plane that also behaves like one: it delivers each commit
/// it publishes to the remaining devices, and lets the next scheduled leaver
/// propose off the back of it.
///
/// That is what makes a multi-generation cascade DETERMINISTIC instead of a
/// race — a leaver can only propose at the epoch the previous eviction produced.
struct CascadePublisher {
    alice: Arc<CircleManager>,
    group: GroupId,
    peers: Vec<Arc<Device>>,
    queue: Mutex<VecDeque<Arc<Device>>>,
    published: Mutex<Vec<Event>>,
    ack: bool,
}

impl CascadePublisher {
    fn new(cascade: &Cascade, queue: Vec<Arc<Device>>, ack: bool) -> Self {
        Self {
            alice: Arc::clone(&cascade.alice),
            group: cascade.mls_group_id.clone(),
            peers: cascade.everyone(),
            queue: Mutex::new(queue.into()),
            published: Mutex::new(Vec::new()),
            ack,
        }
    }

    fn published(&self) -> Vec<Event> {
        self.published.lock().unwrap().clone()
    }
}

impl AutoCommitPublisher for CascadePublisher {
    fn publish_auto_commit<'a>(
        &'a self,
        event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.published.lock().unwrap().push(event.clone());
            // The relay half: every remaining device applies the commit and so
            // reaches the epoch the next proposal must be minted at.
            for peer in &self.peers {
                let _ = peer.manager.session().process_event(event).await;
            }
            let next = self.queue.lock().unwrap().pop_front();
            if let Some(leaver) = next {
                if let Ok(proposal) = leaver.manager.propose_leave(&self.group).await {
                    deliver(&self.alice, &self.peers, &leaver, &proposal).await;
                }
            }
            self.ack
        })
    }
}

// ============================================================================
// 17. The ladder runs until the worklist is empty
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn the_resolve_ladder_runs_until_the_worklist_is_empty() {
    // Three leavers, one after the other. Each eviction's CONFIRM is what
    // applies the next leaver's proposal and stages the next eviction, so a
    // plane that ran one generation would publish the first and abandon two.
    let fx = build_cascade("Ladder Cascade Circle", 3).await;
    let bob = Arc::clone(&fx.peers[0]);
    let carol = Arc::clone(&fx.peers[1]);
    let dave = Arc::clone(&fx.peers[2]);

    fx.propose_leave(&bob).await;
    let work = fx.staged_eviction_work().await;
    let publisher = CascadePublisher::new(&fx, vec![carol, dave], true);

    let ingest = resolve_receive_publish_work(&fx.alice, &publisher, &work).await;

    assert_eq!(
        publisher.published().len(),
        3,
        "every generation the cascade produced must be published by the pass \
         that started it"
    );
    let roster = fx.roster().await;
    assert_eq!(
        roster,
        vec![fx.alice_keys.public_key().to_hex()],
        "and confirmed: all three leavers are out, which only an applied commit does"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "nothing is left owed when the ladder runs to empty"
    );
    assert!(
        fx.alice
            .encrypt_location(
                &fx.mls_group_id,
                &fx.alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
            .await
            .is_ok(),
        "the circle can send again, so no commit is left staged"
    );
    assert!(
        ingest.auto_commits.is_empty(),
        "the ladder hands back no un-run commit: it ran them"
    );
}

// ============================================================================
// 19. A short-lived plane manufactures no orphan
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn an_orphan_is_not_manufactured_by_a_short_lived_plane() {
    // The catch-up sweep runs in a background isolate over its own
    // `CircleManager`. Its `PendingStateRef`s die with it, so any obligation it
    // leaves recorded-but-unredeemed surfaces on the next foreground open as a
    // circle the user is told to rebuild. A ladder that stopped after one
    // generation would manufacture exactly that out of an ordinary triple leave.
    let fx = build_cascade("Ladder Isolate Circle", 3).await;
    let bob = Arc::clone(&fx.peers[0]);
    let carol = Arc::clone(&fx.peers[1]);
    let dave = Arc::clone(&fx.peers[2]);

    fx.propose_leave(&bob).await;
    let work = fx.staged_eviction_work().await;
    let publisher = CascadePublisher::new(&fx, vec![carol, dave], true);
    // The sweep's own entry point: `catchup::resolve_publish_work` is this call
    // over its `RelayManager`.
    let _ = resolve_receive_publish_work(&fx.alice, &publisher, &work).await;

    // The isolate dies. The temp dir is MOVED out so the reopen finds the SAME
    // database — a fresh one would pass this assertion for the wrong reason.
    let Cascade {
        alice,
        alice_keys,
        alice_dir,
        ..
    } = fx;
    drop(publisher);
    drop(alice);

    let reborn = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).expect("reopen");
    assert!(
        reborn.orphaned_removal_deferrals().is_empty(),
        "a plane that finished its cascade leaves no durable obligation behind, \
         so the next foreground open reports nothing"
    );
    assert!(
        reborn.owed_removal_commits().is_empty(),
        "and no durable row at all"
    );
}

// ============================================================================
// The cap: a disposition, never a dangling ref — one case per plane policy
// ============================================================================

// The cap bounds the WORK one ladder call does, so it is reached with MANY
// CIRCLES rather than with a deep cascade — one leaver each, one commit each.
// That is not a convenience: an engine batch is not single-group, so the shape
// that actually reaches the cap in the field is a device holding many circles
// that all lose a member, not a single circle losing seventeen in a row. It is
// also the only affordable shape. A cascade of k leavers in ONE circle costs
// O(k^3) here — every generation delivers a commit to k devices and every device
// applies it against a k-member tree — measured in this tree, debug build:
//
//     k=3  3.5 s    k=5  12.4 s    k=7  39.1 s    k=9  115.9 s
//
// which puts seventeen past forty minutes. Seventeen two-member circles are
// linear — measured here at ~10 s for the cap arm and ~24 s for the redemption
// pass's (which needs 33).
//
// The fold's own `MAX_FOLD_BATCHES` is NOT reached this way, and no plane can
// reach it at all: it counts engine BATCHES inside one fold, which needs 33
// groups in a single `pending_convergence` drain, and `collect_effects` empties
// that buffer on the way out of every engine call while the only scheduler a
// resolution reaches is single-group. Its disposition is driven in-crate, where
// the fold can be handed its batch directly
// (`circle::manager::tests::the_batch_cap_stops_generating_without_dropping_what_it_holds`).

#[tokio::test(flavor = "multi_thread")]
async fn a_deferring_plane_gives_every_commit_it_will_not_run_a_disposition() {
    // The other plane policy. A background burst runs NO generation at all —
    // opening a publish-before-apply window inside a wake the OS may end is what
    // OD4-c forbids — so its disposition has to be the same shape as the cap's:
    // parked, owed, never rolled back.
    let fx = build_cascade("Ladder Burst Circle", 2).await;
    let bob = Arc::clone(&fx.peers[0]);
    fx.propose_leave(&bob).await;
    let work = fx.staged_eviction_work().await;
    let publisher = CascadePublisher::new(&fx, vec![], true);

    let (deferred, ingest) = resolve_receive_publish_work_with_policy(
        &fx.alice,
        &publisher,
        &work,
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;

    assert_eq!(deferred, 1, "the commit is parked, and the caller is told");
    assert!(
        publisher.published().is_empty(),
        "a burst puts nothing on the wire"
    );
    assert!(
        fx.alice.owed_removal_commits().contains(&fx.nostr_group_id),
        "parked means OWED: the obligation is durable"
    );
    assert!(
        fx.alice.orphaned_removal_deferrals().is_empty(),
        "and this session can still redeem it"
    );
    assert!(
        ingest.results.is_empty() && ingest.auto_commits.is_empty(),
        "nothing was resolved, so there is no batch to hand back"
    );
}

// ============================================================================
// The location a resolution replays reaches the plane, not just the store
// ============================================================================

#[tokio::test(flavor = "multi_thread")]
async fn a_location_replayed_by_the_planes_own_resolution_reaches_the_plane() {
    // The eviction's publish-before-apply window buffers whatever arrives behind
    // it. Confirming it replays that — and the plane has to be handed the result,
    // or the map shows nothing until the next delivery from that peer.
    let fx = build_cascade("Ladder Replay Circle", 2).await;
    let bob = Arc::clone(&fx.peers[0]);
    let carol = Arc::clone(&fx.peers[1]);

    // Minted BEFORE the leave reaches her: a device holding a peer's pending
    // `SelfRemove` is send-gated, which is the engine's business and not this
    // test's subject.
    let (carol_fix, _, _) = carol
        .manager
        .encrypt_location(
            &fx.mls_group_id,
            &carol.keys.public_key(),
            &LocationMessage::new(45.46, 9.19),
            300,
        )
        .await
        .expect("carol encrypts");

    fx.propose_leave(&bob).await;
    let work = fx.staged_eviction_work().await;

    // Carol's fix arrives while Alice's eviction commit is staged.
    fx.alice
        .session()
        .process_event(&carol_fix)
        .await
        .expect("alice takes carol's fix");

    let publisher = CascadePublisher::new(&fx, vec![], true);
    let ingest = resolve_receive_publish_work(&fx.alice, &publisher, &work).await;

    assert!(
        ingest.results.iter().any(|r| matches!(
            r,
            LocationMessageResult::Location { sender_pubkey, .. } if *sender_pubkey == carol.hex()
        )),
        "the plane is handed the replayed fix, so it can route it to the UI"
    );
    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
        .expect("snapshot");
    assert!(
        rows.iter().any(|r| r.sender_pubkey == carol.hex()),
        "and the core has already persisted it, which is why no plane re-persists"
    );
}

// A drained `GroupEvolution` carrying welcomes (O3) is NOT driven from a plane
// here: the arm needs a queued outbound Invite AND a `SelfRemove`
// scheduled-but-not-yet-due at the instant the fold re-advances convergence,
// because `converge_and_drain_queued_outbound_intents` returns early whenever
// the eviction IS due (`message_processor/mod.rs:216-221`). That is the engine's
// jitter race, and a test that waits on it is a flaky test. The arm's behaviour
// is covered in-crate by
// `circle::manager::tests::a_drained_group_evolution_is_surfaced_with_its_welcomes_noted`
// and its trace by
// `security_rule_gates::drained_group_evolution_welcomes_are_never_dropped_silently`.

// ============================================================================
// route_results: a resolution's replay is keyed off each result's OWN circle
// ============================================================================

/// A recording relay plane that also strands one event in the engine's global
/// buffers at publish time.
///
/// The engine's effect buffers are not per-group: a call that fails mid-way
/// leaves what it already emitted in them, and the NEXT `collect_effects` —
/// here, the confirm of a completely different circle's eviction — drains it.
/// That is how one resolution batch comes to span two circles, and it is exactly
/// the case an ambient `nostr_group_id` would file under the wrong one.
struct StrandingPublisher {
    alice: Arc<CircleManager>,
    db: std::path::PathBuf,
    stranded: Mutex<Option<Event>>,
}

impl AutoCommitPublisher for StrandingPublisher {
    fn publish_auto_commit<'a>(
        &'a self,
        _event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            let stranded = self.stranded.lock().unwrap().take();
            if let Some(event) = stranded {
                let key = StorageConfig::test_sqlcipher_key().expect("test key");
                set_stored_message_write_fault_for_test(&self.db, &key, true).expect("arm");
                let _ = self.alice.session().process_event(&event).await;
                set_stored_message_write_fault_for_test(&self.db, &key, false).expect("disarm");
            }
            true
        })
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_replayed_location_reaches_the_bus_under_its_own_circle() {
    let fx = build_cascade("Router Home Circle", 2).await;
    let bob = Arc::clone(&fx.peers[0]);

    // A second circle in Alice's OWN store, whose peer's fix will ride the first
    // circle's resolution.
    let (dave_manager, dave_keys, dave_member, _dave_dir) = mint_device().await;
    let relays = vec![GROUP_RELAY.to_string()];
    let sibling = fx
        .alice
        .create_circle(
            &fx.alice_keys,
            vec![dave_member],
            &CircleConfig::new("Router Sibling Circle").with_relays(relays.clone()),
            &relays,
        )
        .await
        .expect("create the sibling circle");
    fx.alice
        .confirm_published(sibling.pending)
        .await
        .expect("confirm the sibling create");
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
        .encrypt_location(
            &sibling.circle.mls_group_id,
            &dave_keys.public_key(),
            &LocationMessage::new(-22.9, -43.17),
            300,
        )
        .await
        .expect("dave encrypts")
        .0;

    let publisher = Arc::new(StrandingPublisher {
        alice: Arc::clone(&fx.alice),
        db: StorageConfig::new(fx.alice_dir.path()).database_path(),
        stranded: Mutex::new(Some(dave_fix)),
    });
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::with_publisher(
        Arc::clone(&fx.alice),
        bus,
        publisher as Arc<dyn AutoCommitPublisher>,
    );

    // The home circle's leave drives a resolution; the sibling's fix rides it.
    // Minted without handing it to Alice: the PLANE is what must ingest it, or
    // the engine answers the plane's copy "already seen" and stages nothing.
    let proposal = fx.mint_leave(&bob).await;
    let _ = processor
        .process_group_event(&proposal, &fx.nostr_group_id)
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
        "a location a resolution replayed must reach the bus under ITS OWN \
         circle — the ambient subscription id belongs to a circle that peer is \
         not even in"
    );
    assert!(
        !routed
            .iter()
            .any(|(ngid, _)| ngid.as_slice() == fx.nostr_group_id.as_slice()),
        "and never under the circle whose event happened to trigger the pass"
    );
}

// ============================================================================
// The cap, driven through the production entry point
// ============================================================================

/// One circle of Alice + one peer, with that peer's eviction already staged and
/// waiting for a plane to resolve it.
struct ArmedCircle {
    work: PublishWork,
    nostr_group_id: [u8; 32],
    mls_group_id: GroupId,
    peer: Arc<Device>,
    _dir: TempDir,
}

/// Builds `count` such circles inside ONE `CircleManager`.
///
/// Two members each, so the cost is linear in circles: the expensive axis is
/// members-per-circle, not circles.
async fn arm_many_circles(
    alice: &Arc<CircleManager>,
    alice_keys: &Keys,
    count: usize,
) -> Vec<ArmedCircle> {
    let relays = vec![GROUP_RELAY.to_string()];
    let mut armed = Vec::with_capacity(count);
    for index in 0..count {
        let (manager, keys, member, dir) = mint_device().await;
        let result = alice
            .create_circle(
                alice_keys,
                vec![member],
                &CircleConfig::new(format!("Cap Circle {index}")).with_relays(relays.clone()),
                &relays,
            )
            .await
            .expect("create circle");
        alice
            .confirm_published(result.pending)
            .await
            .expect("confirm creation");
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
            .expect("the peer proposes leave");
        alice
            .session()
            .process_event(&proposal)
            .await
            .expect("alice ingests the proposal");

        // The engine re-queues the group until the jitter-delayed due time
        // passes, so a single advance would strand the eviction.
        let mut staged = None;
        for _ in 0..40 {
            let effects = alice
                .session()
                .advance_convergence(&group)
                .await
                .expect("advance convergence");
            if let Some(item) = effects
                .publish
                .into_iter()
                .find(|w| matches!(w, PublishWork::AutoPublish { .. }))
            {
                staged = Some(item);
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        armed.push(ArmedCircle {
            work: staged.expect("the eviction surfaces within the jitter window"),
            nostr_group_id: result.circle.nostr_group_id,
            mls_group_id: group,
            peer,
            _dir: dir,
        });
    }
    armed
}

#[tokio::test(flavor = "multi_thread")]
async fn a_commit_past_the_runaway_cap_is_owed_and_redeemable_never_dropped() {
    // One more circle than the cap will run, so the ladder must stop mid-batch.
    // What it must NOT do is roll one back (the permanent silent drop) or walk
    // away from it (a staged commit with nothing recording the debt). It parks:
    // owed, redeemable by this session, and published by the very next
    // redemption pass.
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let armed = arm_many_circles(&alice, &alice_keys, RESOLVE_RUNAWAY_CAP + 2).await;

    // One of the two the cap will not run has had its circle torn down in the
    // meantime — the user left it while this wake was mid-ladder. Its park
    // therefore cannot be RECORDED (the obligation row is keyed by a circle that
    // no longer exists), which is the one case where the ladder has neither a
    // publish nor a durable debt to fall back on.
    let over_ngid = armed.last().expect("a circle past the cap").nostr_group_id;
    let unrecordable = &armed[RESOLVE_RUNAWAY_CAP];
    alice
        .complete_leave(&unrecordable.mls_group_id, chrono::Utc::now().timestamp())
        .await
        .expect("the user leaves that circle");

    let work: Vec<PublishWork> = armed.iter().map(|c| c.work.clone()).collect();
    let publisher = FlatPublisher::new(true);
    // Under a live logger, because that is how the product runs and because the
    // cap's REPORT is half of its disposition: a cap that stopped silently would
    // be the invisible wedge this whole obligation machinery exists to prevent.
    let mut ingest = None;
    let lines = capture_haven_log(async {
        ingest = Some(resolve_receive_publish_work(&alice, &publisher, &work).await);
    })
    .await;
    let ingest = ingest.expect("the ladder ran");
    assert_cap_reported_without_naming_anyone(&lines, over_ngid, &alice_keys);

    assert_eq!(
        publisher.published().len(),
        RESOLVE_RUNAWAY_CAP,
        "the cap bounds the work of ONE call: it runs exactly that many and no more"
    );
    assert!(
        ingest.auto_commits.is_empty(),
        "and it hands nothing back — the un-run commits are parked, not returned \
         for the caller to guess at"
    );

    let over = armed.last().expect("the circle past the cap");
    assert_eq!(over.nostr_group_id, over_ngid);
    assert!(
        alice.owed_removal_commits().contains(&over.nostr_group_id),
        "the commit the cap refused to run is OWED"
    );
    assert!(
        alice.orphaned_removal_deferrals().is_empty(),
        "and redeemable: this session still holds its pending ref"
    );
    assert!(
        alice
            .encrypt_location(
                &over.mls_group_id,
                &alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
            .await
            .is_err(),
        "nothing was rolled back either — the un-run commit is still staged, \
         which is what keeps the removal from being silently dropped"
    );
    for done in &armed[..RESOLVE_RUNAWAY_CAP] {
        assert!(
            !alice.owed_removal_commits().contains(&done.nostr_group_id),
            "a commit the ladder DID run discharged its own obligation"
        );
    }

    // The un-recordable one: no publish, no durable debt — and above all no
    // rollback. A rollback would put the leaver back in this device's projected
    // roster and drop the removal for good, which is strictly worse than a
    // commit left staged with nobody watching it.
    assert!(
        !alice
            .owed_removal_commits()
            .contains(&unrecordable.nostr_group_id),
        "precondition: there is no circle left to key an obligation under"
    );
    assert!(
        !alice
            .session()
            .member_pubkeys(&unrecordable.mls_group_id)
            .await
            .expect("the projected roster still reads")
            .contains(&unrecordable.peer.hex()),
        "the eviction is still STAGED: rolling it back to tidy up would restore \
         the leaver and lose the removal permanently"
    );

    // The park is genuinely redeemable: the next pass lands it.
    let redeemed = alice.redeem_removal_deferrals(&publisher, None).await;
    assert_eq!(redeemed, 1, "the parked commit is published and confirmed");
    assert!(
        alice.owed_removal_commits().is_empty(),
        "and nothing is owed afterwards"
    );
    assert!(
        alice
            .encrypt_location(
                &over.mls_group_id,
                &alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
            .await
            .is_ok(),
        "the circle sends again, which only an applied commit allows"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pending_ref_handed_twice_is_resolved_once() {
    // The `resolved` set's whole job. A second resolution of a ref the first
    // already confirmed would apply a commit the group has merged — and on the
    // rollback rung it would discard one the group is waiting on.
    let fx = build_cascade("Ladder Duplicate Circle", 2).await;
    let bob = Arc::clone(&fx.peers[0]);
    fx.propose_leave(&bob).await;
    let work = fx.staged_eviction_work().await;
    let item = work
        .into_iter()
        .find(|w| matches!(w, PublishWork::AutoPublish { .. }))
        .expect("the eviction surfaces");

    let publisher = FlatPublisher::new(true);
    let doubled = [item.clone(), item];
    let _ = resolve_receive_publish_work(&fx.alice, &publisher, &doubled).await;

    assert_eq!(
        publisher.published().len(),
        1,
        "one ref, one publish — a duplicate must be skipped, not published twice"
    );
    assert!(
        !fx.roster().await.contains(&bob.hex()),
        "and the one resolution it did make applied: the leaver is out"
    );
    assert!(
        fx.alice.owed_removal_commits().is_empty(),
        "with its obligation discharged by the confirm"
    );
}

/// The cap's report exists and says nothing a Rule-15 needle would catch.
fn assert_cap_reported_without_naming_anyone(
    lines: &[helpers::LogLine],
    ngid: [u8; 32],
    keys: &Keys,
) {
    assert!(
        haven_core_lines(lines).iter().any(|l| l
            .message
            .contains("resolve ladder stopped at the runaway cap")),
        "the cap reports what it stood down from"
    );
    assert_some_line_from(lines, "haven_core");
    assert_no_needles(
        &haven_core_lines(lines),
        &[
            &hex::encode(ngid),
            &keys.public_key().to_hex(),
            "Cap Circle 0",
        ],
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_teardown_stops_the_redemption_pass_without_losing_an_obligation() {
    // The pass runs under the live-sync lifecycle lock, so a cascade of relay
    // round-trips is a logout that looks hung. It yields — and what it yields
    // keeps its durable row, so the circle is reported at the next foreground
    // open rather than forgotten.
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let armed = arm_many_circles(&alice, &alice_keys, 2).await;

    let park = FlatPublisher::new(true);
    let work: Vec<PublishWork> = armed.iter().map(|c| c.work.clone()).collect();
    let _ = resolve_receive_publish_work_with_policy(
        &alice,
        &park,
        &work,
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;
    assert_eq!(
        alice.owed_removal_commits().len(),
        2,
        "precondition: both circles owe a publish"
    );

    let teardown = std::sync::atomic::AtomicBool::new(true);
    let publisher = FlatPublisher::new(true);
    let confirmed = alice
        .redeem_removal_deferrals(&publisher, Some(&teardown))
        .await;

    assert_eq!(
        confirmed, 0,
        "a raised teardown stops the pass before it runs"
    );
    assert!(
        publisher.published().is_empty(),
        "and nothing goes on the wire after the caller asked to stop"
    );
    assert_eq!(
        alice.owed_removal_commits().len(),
        2,
        "nothing is discharged and nothing is rolled back: both still owe"
    );

    // Lowered, the same pass completes — so the check is a yield, not a wedge.
    teardown.store(false, std::sync::atomic::Ordering::Release);
    assert_eq!(
        alice
            .redeem_removal_deferrals(&publisher, Some(&teardown))
            .await,
        2,
        "with the teardown clear the pass runs to the end"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_redemption_pass_stops_at_its_cap_with_everything_still_owed() {
    // `redeem_removal_deferrals` runs the same worklist shape as the ladder, so
    // it carries the same runaway guard — and must carry the same disposition.
    // One more owed commit than the cap will run, so the pass stops mid-list:
    // what it did not reach is still owed, still redeemable, and still staged.
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap());
    let armed = arm_many_circles(&alice, &alice_keys, MAX_REDEMPTION_STEPS + 1).await;

    // Parked rather than published, which is exactly what the map the redemption
    // pass reads is filled from.
    let park = FlatPublisher::new(true);
    let work: Vec<PublishWork> = armed.iter().map(|c| c.work.clone()).collect();
    // The ladder's own cap parks the tail rather than running it, which is the
    // same disposition — so every circle ends up owed either way, which is all
    // this precondition needs.
    let _ = resolve_receive_publish_work_with_policy(
        &alice,
        &park,
        &work,
        ReceiveAutoCommitPolicy::DeferToForeground,
    )
    .await;
    assert!(
        park.published().is_empty(),
        "precondition: a deferring plane puts nothing on the wire"
    );
    assert_eq!(
        alice.owed_removal_commits().len(),
        MAX_REDEMPTION_STEPS + 1,
        "precondition: every circle owes a publish before the pass begins"
    );

    let publisher = FlatPublisher::new(true);
    let confirmed = alice.redeem_removal_deferrals(&publisher, None).await;

    assert_eq!(
        confirmed, MAX_REDEMPTION_STEPS,
        "the pass runs exactly its cap's worth and stops"
    );
    assert_eq!(
        alice.owed_removal_commits().len(),
        1,
        "and the one it did not reach is still OWED, not abandoned"
    );
    assert!(
        alice.orphaned_removal_deferrals().is_empty(),
        "still redeemable: this session holds its ref"
    );
    let left = alice
        .owed_removal_commits()
        .into_iter()
        .next()
        .expect("one owed circle");
    let stranded = armed
        .iter()
        .find(|c| c.nostr_group_id == left)
        .expect("it is one of this test's circles");
    assert!(
        alice
            .encrypt_location(
                &stranded.mls_group_id,
                &alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                300,
            )
            .await
            .is_err(),
        "nothing was rolled back: its commit is still staged"
    );

    // …and the very next pass lands it, which is what makes the cap a pause
    // rather than a loss.
    assert_eq!(
        alice.redeem_removal_deferrals(&publisher, None).await,
        1,
        "the next pass redeems the remainder"
    );
    assert!(alice.owed_removal_commits().is_empty());
}
