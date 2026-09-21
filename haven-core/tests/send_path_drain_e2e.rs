//! A SEND drains the engine's buffers too — and drops what it finds there.
//!
//! `cgka-engine`'s `do_send` calls `should_queue_outbound_intent` for every
//! intent, which settles stored convergence first: `retry_deferred_peels`
//! re-ingests a peer message that could not be peeled when it arrived, pushing
//! `GroupEvent::MessageReceived` into the engine's global event buffer. That
//! send's own `collect_effects` then drains it — and Haven's `take_*` helpers
//! read `effects.publish` for the one item they were after and threw
//! `effects.events` away.
//!
//! This is the same defect as the publish-before-apply one, at the HIGHEST
//! frequency there is: it rides every location publish cycle.

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, PublishWork};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use tempfile::TempDir;

const GROUP_RELAY: &str = "wss://group.example.com";

struct Device {
    manager: CircleManager,
    keys: Keys,
}

impl Device {
    fn hex(&self) -> String {
        self.keys.public_key().to_hex()
    }
}

struct Fixture {
    alice: CircleManager,
    alice_keys: Keys,
    peers: Vec<Device>,
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
    (
        manager,
        keys,
        MemberKeyPackage {
            key_package_event,
            inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
            nip65_relays: vec![],
        },
        dir,
    )
}

async fn build_circle(name: &str, peer_count: usize) -> Fixture {
    let relays = vec![GROUP_RELAY.to_string()];
    let mut peers = Vec::new();
    let mut key_packages = Vec::new();
    let mut dirs = Vec::new();
    for _ in 0..peer_count {
        let (manager, keys, member, dir) = mint_device().await;
        peers.push(Device { manager, keys });
        key_packages.push(member);
        dirs.push(dir);
    }
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let result = alice
        .create_circle(
            &alice_keys,
            key_packages,
            &CircleConfig::new(name).with_relays(relays.clone()),
            &relays,
        )
        .await
        .expect("create circle");
    alice
        .confirm_published(result.pending)
        .await
        .expect("confirm creation");
    for peer in &peers {
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == peer.hex())
            .expect("a welcome per member");
        peer.manager
            .process_gift_wrapped_invitation(&peer.keys, &welcome.event)
            .await
            .expect("peer holds the welcome");
        peer.manager
            .accept_invitation(&welcome.event.id)
            .await
            .expect("peer accepts");
    }
    dirs.push(alice_dir);
    Fixture {
        alice,
        alice_keys,
        peers,
        mls_group_id: result.circle.mls_group_id.clone(),
        nostr_group_id: result.circle.nostr_group_id,
        _dirs: dirs,
    }
}

/// Drains `manager`'s convergence until a `SelfRemove` auto-commit is staged,
/// returning it as the signed commit a plane would publish plus its ref.
async fn stage_eviction(
    manager: &CircleManager,
    group: &GroupId,
) -> (Event, haven_core::nostr::mls::types::PendingStateRef) {
    for _ in 0..40 {
        let effects = manager
            .session()
            .advance_convergence(group)
            .await
            .expect("advance convergence");
        if let Some((msg, pending)) = effects.publish.iter().find_map(|w| match w {
            PublishWork::AutoPublish { msg, pending } => Some((msg.clone(), *pending)),
            _ => None,
        }) {
            let event = SessionManager::transport_message_to_event(&msg).expect("commit event");
            return (event, pending);
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    panic!("the SelfRemove auto-commit never surfaced within the jitter window");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_peer_location_replayed_during_a_sends_convergence_settling_is_persisted() {
    // Bob runs an epoch AHEAD of Alice: he commits Carol's leave while Alice is
    // still behind, then sends a fix sealed at the new epoch. Alice cannot peel
    // it when it arrives — the kind-445 outer layer is keyed by the sender's
    // epoch exporter — so it is stored deferred. When she finally applies Bob's
    // commit and then SENDS, the engine settles convergence first, retries the
    // deferred peel, and hands the decrypted fix back in that send's own
    // effects. Which is where it used to die.
    let fx = build_circle("Send Drain Circle", 2).await;
    let bob = &fx.peers[0];
    let carol = &fx.peers[1];

    // Carol leaves; BOB commits it, so he is the one who moves ahead.
    let proposal = carol
        .manager
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("carol proposes leave");
    bob.manager
        .session()
        .process_event(&proposal)
        .await
        .expect("bob ingests carol's proposal");
    let (bob_commit, bob_pending) = stage_eviction(&bob.manager, &fx.mls_group_id).await;
    bob.manager
        .confirm_published(bob_pending)
        .await
        .expect("bob confirms his own eviction commit");

    // A fix sealed at the epoch Alice has not reached.
    let (ahead_fix, _, _) = bob
        .manager
        .encrypt_location(
            &fx.mls_group_id,
            &bob.keys.public_key(),
            &LocationMessage::new(37.77, -122.41),
            300,
        )
        .await
        .expect("bob encrypts at the new epoch");
    let screened = fx
        .alice
        .session()
        .process_event(&ahead_fix)
        .await
        .expect("alice takes the future-epoch fix");
    let outcome = screened.ingested().expect("authenticated").outcome;
    assert!(
        !matches!(
            outcome,
            haven_core::nostr::mls::types::IngestOutcome::Processed
        ),
        "precondition: alice must NOT be able to apply it yet, or the settle \
         below has nothing to retry (got {outcome:?})"
    );
    assert!(
        fx.alice
            .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
            .expect("snapshot")
            .is_empty(),
        "precondition: nothing is in the store yet"
    );

    // Alice catches up to the epoch the fix was sealed at. She needs Carol's
    // proposal first: Bob's commit covers it by reference.
    fx.alice
        .session()
        .process_event(&proposal)
        .await
        .expect("alice takes carol's proposal");
    fx.alice
        .session()
        .process_event(&bob_commit)
        .await
        .expect("alice applies bob's commit");

    // …and then SENDS. The settle inside this call is what replays Bob's fix.
    fx.alice
        .encrypt_location(
            &fx.mls_group_id,
            &fx.alice_keys.public_key(),
            &LocationMessage::new(1.0, 2.0),
            300,
        )
        .await
        .unwrap_or_else(|e| panic!("alice's own send still succeeds: {e:?}"));

    let rows = fx
        .alice
        .snapshot_last_known_for_circle(&fx.nostr_group_id, chrono::Utc::now().timestamp())
        .expect("snapshot");
    let bob_row = rows
        .iter()
        .find(|r| r.sender_pubkey == bob.hex())
        .expect("the fix the SEND replayed is delivered exactly once, so the send must persist it");
    assert!((bob_row.latitude - 37.77).abs() < 1e-9);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_deferred_send_still_hands_back_its_drained_proposals() {
    // A regression pin, and the one place `PublishWork::Proposal` is reachable
    // without a race. Bob's own LEAVE is queued — the engine will not encrypt
    // while a stored row it cannot settle is in the convergence window — and the
    // deferred send's repair is what releases it: the sweep retires the stale
    // row, the advance drains the queued intent, and the proposal comes back as
    // publish work. Dropping it there leaves the user's leave with nothing in
    // flight and no way for a peer to commit it.
    let fx = build_circle("Send Proposal Circle", 2).await;
    let bob = &fx.peers[0];

    // A row sealed one epoch above Bob's tip, backdated past the age horizon so
    // the repair's sweep is entitled to retire it.
    let (_carol, _carol_keys, carol_kp, _carol_dir) = mint_device().await;
    let added = fx
        .alice
        .add_members_with_welcomes(
            &fx.alice_keys,
            &fx.mls_group_id,
            vec![carol_kp],
            &[GROUP_RELAY.to_string()],
        )
        .await
        .expect("alice stages an add");
    fx.alice
        .confirm_published(added.pending)
        .await
        .expect("alice confirms the add");
    let ahead = fx
        .alice
        .session()
        .epoch(&fx.mls_group_id)
        .await
        .expect("alice's epoch");
    fx.alice
        .encrypt_location(
            &fx.mls_group_id,
            &fx.alice_keys.public_key(),
            &LocationMessage::new(5.0, 6.0),
            60,
        )
        .await
        .expect("alice sends at the higher epoch");
    let source = fx
        .alice
        .session()
        .stored_convergence_input_for_test(
            &fx.mls_group_id,
            haven_core::nostr::mls::types::OpenMlsContentKind::Application,
            ahead,
        )
        .await
        .expect("alice's own row at the higher epoch");
    bob.manager
        .session()
        .stage_convergence_input_for_test(
            &source,
            haven_core::nostr::mls::types::MessageState::Retryable,
            haven_core::nostr::mls::types::UNRESOLVABLE_INPUT_MAX_AGE_SECS + 1,
        )
        .await
        .expect("stage the stuck row on bob");

    // Bob's leave cannot be encrypted while that row gates the window, so the
    // engine QUEUES it durably.
    assert!(
        bob.manager.propose_leave(&fx.mls_group_id).await.is_err(),
        "precondition: the leave is queued, not sent"
    );

    // …and the next send's repair is what releases it.
    let err = bob
        .manager
        .encrypt_location(
            &fx.mls_group_id,
            &bob.keys.public_key(),
            &LocationMessage::new(1.0, 2.0),
            60,
        )
        .await
        .expect_err("the send defers behind the same row");
    let haven_core::circle::CircleError::SendDeferred { work, .. } = err else {
        panic!("expected a deferred send, got {err:?}");
    };
    assert_eq!(
        work.proposals.len(),
        1,
        "the repair's drained proposal must reach the caller that can publish it"
    );
    assert_eq!(work.proposals[0].kind, nostr::Kind::Custom(445));
}
