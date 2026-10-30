//! A device that missed two or more chained commits drains the backlog on its
//! own — without sending anything (C7, `docs/MDK_UPSTREAM_TRACKER.md` row C7).
//!
//! A relay serves newest first, and a kind-445 commit's outer layer is keyed at
//! its committer's PRE-commit epoch, so the newer commit of a pair cannot be
//! peeled by a device that has not applied the older one: the engine retains it
//! as a `PeelDeferred` row. MDK v0.9.4 retries such rows only from inside
//! `advance_convergence` and schedules no advance for them, so before the fix the
//! row waited for this device's own next seal — for ever, on a member that
//! receives without sending.
//!
//! At v0.10.4 MDK's own signals drain it, and Haven serves them (tracker
//! rows C7, T-SCHEDULER):
//!
//! * **in the pass that applies the older commit**: the advance that settles a
//!   convergence pass retries the deferred-peel sweep itself, and an epoch
//!   change leaves its group owing an advance (Haven's kept edge,
//!   `SessionManager::groups_owing_advance`), which every receive plane
//!   serves in place;
//! * **at the open of a new session**: the engine's hydrate names every group
//!   holding deferred rows in its one-shot `pending_convergence`, which Haven
//!   keeps as the owed-advance set and the first plane drains — after the
//!   open's recovery, whose own drain usually collects those names — so a row
//!   deferred by an earlier process converges with no inbound event and no
//!   send, and a quiet circle costs no advance.
//!
//! The drain after an epoch change is also where the engine re-mints a leaving
//! member's superseded leave, so the last test pins that the live plane
//! publishes it rather than dropping it.
//!
//! The catch-up sweep's two edges are pinned in `catchup_sweep_e2e.rs`, the
//! poll path's in `live_sync_out_of_order_commit_e2e.rs`.

use std::sync::Arc;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::live_sync::{
    CircleSpec, EngineProcessor, EventBus, GroupProcessOutcome, LiveSyncCore, LiveSyncEvent,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use nostr_relay_builder::MockRelay;
use tempfile::TempDir;

mod helpers;

const GROUP_RELAY: &str = "wss://group.example.com";
const SECOND_RELAY: &str = "wss://group-b.example.com";

/// Alice (admin) and Bob, the member who will miss the chain, each with a real
/// on-disk MLS store; Bob's directory is kept so his session can be reopened.
struct Circle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    bob_dir: TempDir,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _alice_dir: TempDir,
}

async fn build_circle() -> Circle {
    let relays = vec![GROUP_RELAY.to_string()];
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
    let key_package_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob's key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let config = CircleConfig::new("Chained Backlog Circle").with_relays(relays.clone());
    let created = alice
        .create_circle(&alice_keys, vec![member], &config)
        .await
        .expect("create circle");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = alice.land_staged_for_test().await;
    let welcome = &created.welcome_events[0];
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("bob holds the welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("bob accepts");

    Circle {
        alice: Arc::new(alice),
        alice_keys,
        bob: Arc::new(bob),
        bob_keys,
        bob_dir,
        mls_group_id: created.circle.mls_group_id.clone(),
        nostr_group_id: created.circle.nostr_group_id,
        _alice_dir: alice_dir,
    }
}

impl Circle {
    async fn epoch(&self, manager: &CircleManager) -> u64 {
        manager.group_epoch(&self.mls_group_id).await.unwrap()
    }

    /// One CONFIRMED admin relay-list commit (Rule 13), returned as the event a
    /// relay would store.
    async fn confirmed_commit(&self, relays: &[&str]) -> Event {
        let relays: Vec<String> = relays.iter().map(|r| (*r).to_string()).collect();
        let commit = self
            .alice
            .update_relays_for_test(&self.mls_group_id, &relays)
            .await
            .expect("alice stages a relay-list commit");
        commit
    }

    /// Alice lands a chain of two commits while Bob is away: `[older, newer]`.
    async fn chain_of_two(&self) -> [Event; 2] {
        let n = self.epoch(&self.alice).await;
        let older = self.confirmed_commit(&[GROUP_RELAY, SECOND_RELAY]).await;
        let newer = self.confirmed_commit(&[GROUP_RELAY]).await;
        assert_eq!(
            self.epoch(&self.alice).await,
            n + 2,
            "precondition: both links applied on the committer"
        );
        [older, newer]
    }

    async fn alice_fix(&self, lat: f64, lon: f64) -> Event {
        self.alice
            .seal_location_for_test(&self.mls_group_id, &LocationMessage::new(lat, lon))
            .await
            .expect("alice seals a fix")
            .0
    }

    /// Leaves Bob exactly where a process killed between two receive advances
    /// leaves him: the older commit applied, the newer one not, and nothing
    /// having advanced the group since.
    ///
    /// Driven through the bare engine seam on purpose — every Haven receive
    /// plane serves each deadline the engine announces, so no plane can produce
    /// this state inside one session. The newer commit cannot peel at Bob's
    /// epoch; the older one is held for its convergence window (MDK's pinned
    /// policy v1). Exactly one advance, at the older commit's cutoff, applies
    /// it; the newer one, peelable only now, opens a second window nothing
    /// serves.
    async fn strand_bob_across_a_restart(self) -> (Self, u64) {
        let [older, newer] = self.chain_of_two().await;
        let n = self.epoch(&self.bob).await;
        for commit in [&newer, &older] {
            self.bob
                .session()
                .process_event(commit)
                .await
                .expect("bob's engine takes the commit");
        }
        let cutoff = self
            .bob
            .session()
            .receive_retick_after(&self.mls_group_id)
            .await
            .expect("the older commit owes a convergence cutoff");
        tokio::time::sleep(cutoff).await;
        self.bob
            .session()
            .advance_for_receive(&self.mls_group_id)
            .await
            .expect("bob serves the older commit's cutoff");
        assert_eq!(
            self.epoch(&self.bob).await,
            n + 1,
            "precondition: the older commit applied and the newer one did not"
        );

        let Self {
            alice,
            alice_keys,
            bob,
            bob_keys,
            bob_dir,
            mls_group_id,
            nostr_group_id,
            _alice_dir: alice_dir,
        } = self;
        drop(bob);
        let bob = Arc::new(
            CircleManager::new_unencrypted(bob_dir.path(), &bob_keys)
                .expect("reopen bob's on-disk store"),
        );
        let reopened = Self {
            alice,
            alice_keys,
            bob,
            bob_keys,
            bob_dir,
            mls_group_id,
            nostr_group_id,
            _alice_dir: alice_dir,
        };
        assert_eq!(
            reopened.epoch(&reopened.bob).await,
            n + 1,
            "precondition: opening the session drains nothing by itself"
        );
        (reopened, n)
    }
}

fn locations_from(rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> Vec<String> {
    let mut senders = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let LiveSyncEvent::Location { sender_pubkey, .. } = event {
            senders.push(sender_pubkey);
        }
    }
    senders
}

/// The in-pass drain on the live plane, the default receive path: the chain arrives
/// newest first, the newer commit is retained, and applying the older one drains
/// it in the same pass — Bob reaches Alice's epoch and decrypts her next fix
/// without ever sealing anything of his own.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_receive_only_member_drains_a_chained_backlog_on_the_live_plane() {
    let fx = build_circle().await;
    let n = fx.epoch(&fx.bob).await;
    let [older, newer] = fx.chain_of_two().await;

    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.bob), bus);

    let outcome = processor
        .process_group_event(&newer, &fx.nostr_group_id)
        .await;
    assert_eq!(
        (outcome, fx.epoch(&fx.bob).await),
        (GroupProcessOutcome::Deferred, n),
        "precondition: the newer commit is sealed a whole epoch above Bob, so it \
         cannot peel and the engine retains it (`TransportDeferred`) rather than \
         applying it"
    );

    let _ = processor
        .process_group_event(&older, &fx.nostr_group_id)
        .await;
    assert_eq!(
        fx.epoch(&fx.bob).await,
        fx.epoch(&fx.alice).await,
        "applying the older commit must drain the retained newer one in the same \
         pass: a member that receives without sending has nothing else that ever \
         would"
    );

    let fix = fx.alice_fix(52.37, 4.89).await;
    let _ = processor
        .process_group_event(&fix, &fx.nostr_group_id)
        .await;
    assert!(
        locations_from(&mut rx).contains(&fx.alice_keys.public_key().to_hex()),
        "and the admin's next fix, sealed at the chain's tip, must reach the map"
    );
}

/// The open's drain on the live plane: a session opened over a retained row that the
/// previous process never drained converges when live sync starts — with no
/// inbound event and no send.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn live_sync_start_drains_a_backlog_an_earlier_process_retained() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let (fx, n) = build_circle().await.strand_bob_across_a_restart().await;

    let engine = LiveSyncCore::new_local(
        Arc::clone(&fx.bob),
        fx.bob_keys.public_key(),
        Arc::new(haven_core::relay::RelayManager::new()),
    );
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode(fx.nostr_group_id),
                relays: vec![url],
            }],
            &[],
        )
        .await
        .expect("bob's engine starts over an empty relay");
    let reached = fx.epoch(&fx.bob).await;
    let _ = engine.stop().await;

    assert_eq!(
        reached,
        n + 2,
        "the relay holds nothing, so the only thing that can move Bob is the \
         start's own advance over every circle"
    );
}

/// The one diagnostic `SessionManager::proposal_events` can emit — a proposal
/// that will not serialize — names nothing (Rule 15): not the circle it was
/// addressed to, not its id, and none of its payload.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unserializable_proposal_is_dropped_without_naming_anything() {
    use cgka_traits::transport::{Timestamp, TransportEnvelope, TransportSource};
    use haven_core::nostr::mls::types::{MessageId, PublishWork, TransportMessage};
    use haven_core::nostr::mls::SessionManager;

    const GROUP: &str = "c7a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f";
    const ID: &str = "5eed0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2";
    let work = [PublishWork::Proposal {
        msg: TransportMessage {
            id: MessageId::new(hex::decode(ID).unwrap()),
            payload: format!("not json {GROUP} {ID}").into_bytes(),
            timestamp: Timestamp(0),
            causal_deps: Vec::new(),
            source: TransportSource(GROUP.to_string()),
            envelope: TransportEnvelope::GroupMessage {
                transport_group_id: hex::decode(GROUP).unwrap(),
            },
        },
        queued_intent: None,
    }];

    let mut events = None;
    let lines = helpers::capture_haven_log(async {
        events = Some(SessionManager::proposal_events(&work));
    })
    .await;

    assert!(
        events.is_some_and(|events| events.is_empty()),
        "precondition: the proposal really was unserializable"
    );
    let ours = helpers::haven_core_lines(&lines);
    helpers::assert_some_line_from(&ours, "haven_core::nostr::mls");
    helpers::assert_no_needles(&ours, &[GROUP, ID]);
}

/// Every location the bus carried, as `(circle, sender)`.
fn routed_from(rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> Vec<(Vec<u8>, String)> {
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
    routed
}

/// A fix the open-time advance releases — retained unpeeled behind its circle's
/// commit — must reach the map under the circle it belongs to, never under
/// another circle the same plane is serving.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fix_the_open_advance_releases_is_routed_to_its_own_circle() {
    let fx = build_circle().await;
    // Circle B: Dave's, with Bob in it.
    let dave_dir = TempDir::new().unwrap();
    let dave_keys = Keys::generate();
    let dave = CircleManager::new_unencrypted(dave_dir.path(), &dave_keys).unwrap();
    let bob_kp = build_kp_maintenance_events(
        fx.bob.session(),
        &fx.bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob's second key package")
    .event;
    let relays = vec![GROUP_RELAY.to_string()];
    let circle_b = dave
        .create_circle(
            &dave_keys,
            vec![MemberKeyPackage {
                key_package_event: bob_kp,
                inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Second Circle").with_relays(relays.clone()),
        )
        .await
        .expect("dave creates circle b");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = dave.land_staged_for_test().await;
    let welcome = &circle_b.welcome_events[0];
    fx.bob
        .process_gift_wrapped_invitation(&fx.bob_keys, &welcome.event)
        .await
        .expect("bob holds the welcome");
    fx.bob
        .accept_invitation(&welcome.event.id)
        .await
        .expect("bob joins circle b");
    let ngid_b = circle_b.circle.nostr_group_id;

    // Circle A: Alice's fix is retained unpeeled behind her commit, which is
    // ingested but left to the plane's own advance.
    let commit = fx.confirmed_commit(&[GROUP_RELAY, SECOND_RELAY]).await;
    let stranded = fx.alice_fix(52.37, 4.89).await;
    for event in [&stranded, &commit] {
        fx.bob
            .session()
            .process_event(event)
            .await
            .expect("bob's engine takes it");
    }

    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(Arc::clone(&fx.bob), bus);
    processor.drain_open_advance().await;

    let dave_fix = dave
        .seal_location_for_test(
            &circle_b.circle.mls_group_id,
            &LocationMessage::new(1.0, 2.0),
        )
        .await
        .expect("dave seals in circle b")
        .0;
    let _ = processor.process_group_event(&dave_fix, &ngid_b).await;

    let routed = routed_from(&mut rx);
    let alice = fx.alice_keys.public_key().to_hex();
    assert!(
        routed.contains(&(fx.nostr_group_id.to_vec(), alice.clone())),
        "the stranded fix must reach the map, under circle A; routed: {} line(s)",
        routed.len()
    );
    assert!(
        !routed.contains(&(ngid_b.to_vec(), alice)),
        "and never under circle B, which the same plane serves"
    );
}

/// An advance made for another reason — a receive's, or a seal's pre-send
/// drain — never takes a circle out of the advances the engine named: only a
/// plane that drains them takes them, so an advance that left the circle
/// unfinished cannot leave it to nobody.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_advance_made_for_another_reason_never_takes_a_circle_out_of_the_owed_set() {
    let fx = build_circle().await;
    let session = fx.bob.session();
    let _ = session.take_owed_advance();
    session.owe_advance(std::slice::from_ref(&fx.mls_group_id));

    session
        .advance_for_receive(&fx.mls_group_id)
        .await
        .expect("a receive's advance");
    session
        .advance_convergence(&fx.mls_group_id)
        .await
        .expect("a user-facing advance");

    assert!(
        session.advances_for_test(&fx.mls_group_id) >= 2,
        "premise: the circle was advanced",
    );
    assert!(
        session.take_owed_advance().contains(&fx.mls_group_id),
        "an incidental advance took the circle out of the owed set",
    );
}

/// Bob joins a second circle, Dave's, where nothing happens; its group.
async fn bob_joins_a_quiet_circle(fx: &Circle) -> GroupId {
    let dave_dir = TempDir::new().unwrap();
    let dave_keys = Keys::generate();
    let dave = CircleManager::new_unencrypted(dave_dir.path(), &dave_keys).unwrap();
    let bob_kp = build_kp_maintenance_events(
        fx.bob.session(),
        &fx.bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob's second key package")
    .event;
    let quiet = dave
        .create_circle(
            &dave_keys,
            vec![MemberKeyPackage {
                key_package_event: bob_kp,
                inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
                nip65_relays: vec![],
            }],
            &CircleConfig::new("Quiet Circle").with_relays(vec![GROUP_RELAY.to_string()]),
        )
        .await
        .expect("dave creates the quiet circle");
    let _ = dave.land_staged_for_test().await;
    let welcome = &quiet.welcome_events[0];
    fx.bob
        .process_gift_wrapped_invitation(&fx.bob_keys, &welcome.event)
        .await
        .expect("bob holds the welcome");
    fx.bob
        .accept_invitation(&welcome.event.id)
        .await
        .expect("bob joins the quiet circle");
    quiet.circle.mls_group_id
}

/// Before the first plane of a reopened session, in each arm: nothing, a seal
/// on the quiet circle, or a seal on the backlog circle itself.
#[derive(Clone, Copy, Debug)]
enum BeforeThePlane {
    Nothing,
    SealOnQuiet,
    SealOnBacklog,
}

/// A reopened session advances exactly the circles the engine names at its
/// open. Circle A holds, from an earlier process, a commit buffered with the
/// admin's fix retained unpeeled behind it — and no relay holds anything for
/// A — while circle B is quiet. The first plane drains A to the admin's
/// epoch and the fix reaches the store, and gives B no advance: whether that
/// plane comes first, comes after a seal on B has collected the engine's
/// one-shot names, or after a seal on A advanced A for its own reasons.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reopened_session_advances_exactly_the_circles_the_engine_names_at_its_open() {
    use haven_core::relay::fanout::{scripted::Inert, DriveMode, Publishing, WallClock};
    for arm in [
        BeforeThePlane::Nothing,
        BeforeThePlane::SealOnQuiet,
        BeforeThePlane::SealOnBacklog,
    ] {
        let fx = build_circle().await;
        let quiet_group = bob_joins_a_quiet_circle(&fx).await;

        let commit = fx.confirmed_commit(&[GROUP_RELAY, SECOND_RELAY]).await;
        let retained = fx.alice_fix(52.37, 4.89).await;
        for event in [&retained, &commit] {
            fx.bob
                .session()
                .process_event(event)
                .await
                .expect("bob's engine takes it");
        }
        let behind = fx.epoch(&fx.bob).await;
        let Circle {
            alice,
            alice_keys,
            bob,
            bob_keys,
            bob_dir,
            mls_group_id,
            nostr_group_id,
            _alice_dir,
        } = fx;
        drop(bob);
        let bob = Arc::new(
            CircleManager::new_unencrypted(bob_dir.path(), &bob_keys)
                .expect("reopen bob's on-disk store"),
        );
        assert!(
            bob.group_epoch(&mls_group_id).await.unwrap() == behind,
            "premise: opening the session drains nothing by itself ({arm:?})",
        );

        let seal_on = |group: GroupId| {
            let bob = Arc::clone(&bob);
            async move {
                let _ = Publishing::<'_, Inert> {
                    fanout: &Inert,
                    publisher: &Inert,
                    clock: &WallClock,
                    deadline_ms: None,
                    mode: &DriveMode::FinishOnly,
                }
                .seal_location(&bob, &group, &LocationMessage::new(1.0, 2.0))
                .await;
            }
        };
        match arm {
            BeforeThePlane::Nothing => {}
            BeforeThePlane::SealOnQuiet => seal_on(quiet_group.clone()).await,
            BeforeThePlane::SealOnBacklog => seal_on(mls_group_id.clone()).await,
        }
        let quiet_advances = bob.session().advances_for_test(&quiet_group);

        let processor = EngineProcessor::new(Arc::clone(&bob), EventBus::new());
        processor.drain_open_advance().await;

        assert_eq!(
            bob.group_epoch(&mls_group_id).await.unwrap(),
            alice.group_epoch(&mls_group_id).await.unwrap(),
            "the first plane did not drain the circle the engine named ({arm:?})",
        );
        assert!(
            bob.snapshot_last_known_for_circle(&nostr_group_id, chrono::Utc::now().timestamp())
                .expect("snapshot")
                .iter()
                .any(|loc| loc.sender_pubkey == alice_keys.public_key().to_hex()),
            "the fix retained behind the commit never reached the store ({arm:?})",
        );
        assert_eq!(
            bob.session().advances_for_test(&quiet_group),
            quiet_advances,
            "the first plane advanced a circle nobody named ({arm:?})",
        );
    }
}

/// A kind-445 for the circle routed by `routing` that nobody can decrypt:
/// its public `h` tag on random bytes, signed by a throwaway key.
fn undecryptable(routing: &[u8; 32]) -> Event {
    use rand::RngCore as _;
    let mut bytes = [0u8; 96];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    nostr::EventBuilder::new(
        nostr::Kind::Custom(445),
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes),
    )
    .tag(nostr::Tag::custom(
        nostr::TagKind::custom("h"),
        [hex::encode(routing)],
    ))
    .sign_with_keys(&Keys::generate())
    .expect("a forged envelope")
}

/// A deferred peel owes its circle an advance only while it is due to be
/// tried again — re-armed by a new epoch. One that has had its try at the
/// current epoch answers only its remaining residence (up to 30 days), and
/// owes nothing: an undecryptable envelope anyone with the public tag can
/// publish must not make every claim point re-advance the circle for a
/// month. A store that cannot say still reads as owed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tried_deferred_peel_owes_no_advance_and_a_rearmed_one_does() {
    use haven_core::nostr::mls::types::{IngestOutcome, ScreenedIngest};
    let fx = helpers::setup_circle(3, &["wss://group.example.com"]).await;
    let (admin, member) = (fx.admin(), &fx.members[1]);
    let session = member.session();
    let routing = member
        .circle
        .get_circle(&fx.group)
        .await
        .expect("read")
        .expect("the circle")
        .circle
        .nostr_group_id;
    // MDK's whole per-circle deferral store, so the advance that applies the
    // commit below leaves rows untried.
    loop {
        let ScreenedIngest::Ingested(ingest) = session
            .process_event(&undecryptable(&routing))
            .await
            .expect("an undecryptable envelope is not an ingest failure")
        else {
            panic!("a well-formed envelope passes the pre-auth screen");
        };
        match ingest.outcome {
            IngestOutcome::TransportDeferred { .. } => {}
            IngestOutcome::ResourceRefused { .. } => break,
            _ => panic!("an undecryptable envelope is deferred or refused"),
        }
    }
    let removal = admin
        .circle
        .remove_members_for_test(&fx.group, &[fx.members[2].pubkey_hex()])
        .await
        .expect("the admin removes the third member");
    let before = session.epoch(&fx.group).await.expect("epoch");
    session.process_event(&removal).await.expect("ingest");
    for _ in 0..40 {
        if session.epoch(&fx.group).await.expect("epoch") > before {
            break;
        }
        if let Some(after) = session.receive_retick_after(&fx.group).await {
            tokio::time::sleep(after).await;
        }
        session
            .advance_convergence(&fx.group)
            .await
            .expect("advance");
    }
    assert!(
        session.deferred_peels_untried_for_test(&fx.group).await,
        "premise: the new epoch re-armed the flood"
    );
    assert!(
        session.still_owes_advance(&fx.group).await,
        "a deferred peel the new epoch re-armed is owed an advance"
    );
    for _ in 0..400 {
        if !session.deferred_peels_untried_for_test(&fx.group).await {
            break;
        }
        session
            .advance_convergence(&fx.group)
            .await
            .expect("advance");
    }
    assert!(
        !session.deferred_peels_untried_for_test(&fx.group).await,
        "premise: every row has had its try at this epoch"
    );
    assert!(
        !session.still_owes_advance(&fx.group).await,
        "rows that only wait out their residence owe the circle nothing"
    );
}
