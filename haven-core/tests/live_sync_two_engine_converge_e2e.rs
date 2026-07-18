//! Two-engine convergence integration test over an in-process `MockRelay`
//! (Dark Matter port, DM-5a).
//!
//! # What changed
//!
//! The pre-migration suite drove the hand-rolled settle-window / `converge_commit`
//! / `CommitConvergence` / `CommitIntent` / `MlsWriteGate` machinery (R1 flagship,
//! R2 buffer, R5 write-gate). That whole layer is DELETED — the engine owns
//! convergence now (`ingest` + `advance_convergence`). Re-expressed here is the
//! SURVIVING invariant the coordinator called out: **two wired `LiveSyncCore`s
//! over one relay converge to the same epoch/state through the engine loop, with
//! NO settle-window choreography.** A member's commit, published to the shared
//! relay, is received + converged by the peer engine (ingest → advance), both
//! land on the same epoch, and the group cross-decrypts BOTH ways (the only twin-
//! fork detector — equal epoch NUMBER alone cannot detect a twin fork).
//!
//! DELETED-WITH-SUBJECT: R2 (`settle().competitor_count` buffer) and R5
//! (`MlsWriteGate` serialization) — the settle buffer + per-circle write gate are
//! superseded by the engine's single `tokio::sync::Mutex<AccountDeviceSession>`
//! (Rule 14; structurally guarded by the inline
//! `single_account_device_session_construction_site` test).

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys, PublicKey};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

/// A genuine two-member circle (Alice admin + Bob co-member), each with their own
/// real MLS store, ready to wrap in a [`LiveSyncCore`].
struct TwoMemberCircle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _alice_dir: TempDir,
    _bob_dir: TempDir,
}

/// Builds Alice + Bob as real co-members via the PUBLIC circle API (create →
/// confirm → welcome → accept), so Bob is a genuine member whose location Alice
/// can cross-decrypt.
async fn build_two_member_circle() -> TwoMemberCircle {
    let relays = vec!["wss://group.example.com".to_string()];

    // Bob: a real manager whose own KeyPackage lets him join.
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();
    let bob_kp_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
    )
    .await
    .expect("bob key package")
    .event;
    let bob_member = MemberKeyPackage {
        key_package_event: bob_kp_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    // Alice: admin, creates the circle including Bob.
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();
    let config = CircleConfig::new("Two Engine Converge Circle").with_relays(relays.clone());
    let result = alice
        .create_circle(&alice_keys, vec![bob_member], &config, &relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

    // Bob joins from the gift-wrapped welcome.
    let welcome = &result.welcome_events[0];
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("bob processes welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("bob accepts");

    TwoMemberCircle {
        alice: Arc::new(alice),
        alice_keys,
        bob: Arc::new(bob),
        bob_keys,
        mls_group_id,
        nostr_group_id,
        _alice_dir: alice_dir,
        _bob_dir: bob_dir,
    }
}

/// Whether `decryptor` can decrypt a fresh Location `encryptor` sends for the
/// group — the sole reliable detector of a TWIN fork (same epoch number but a
/// different exporter secret).
async fn cross_decrypts(
    encryptor: &CircleManager,
    encryptor_pubkey: &PublicKey,
    decryptor: &CircleManager,
    gid: &GroupId,
) -> bool {
    let location = LocationMessage::new(40.12, -74.34);
    let Ok((event, _, _)) = encryptor
        .encrypt_location(gid, encryptor_pubkey, &location, 300)
        .await
    else {
        return false;
    };
    matches!(
        decryptor.decrypt_location(&event).await,
        Ok(ref results) if results.iter().any(|r| matches!(r, LocationMessageResult::Location { .. }))
    )
}

/// Publishes an already-built event to `url`.
async fn publish_event(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    publisher.send_event(event).await.expect("publish event");
}

/// TWO wired engines over ONE relay converge through the engine loop: Alice's
/// admin commit, published to the shared relay, is received + converged by Bob's
/// engine (ingest → advance), both land on the SAME epoch N+1, and the group
/// cross-decrypts BOTH ways — no settle-window choreography.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_engines_converge_over_one_relay_via_the_engine_loop() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let fx = build_two_member_circle().await;
    let hex = hex::encode(fx.nostr_group_id);

    // One engine per member, both over the SAME relay, both subscribed to #h.
    let alice_engine = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    let bob_engine = LiveSyncCore::new_local(Arc::clone(&fx.bob), fx.bob_keys.public_key());
    let spec = CircleSpec {
        group_id_hex: hex.clone(),
        relays: vec![url.clone()],
    };
    alice_engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("alice engine starts");
    bob_engine
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("bob engine starts");
    tokio::time::sleep(Duration::from_millis(500)).await; // both REQs register

    let n = fx.alice.group_epoch(&fx.mls_group_id).await.unwrap();
    assert_eq!(
        n,
        fx.bob.group_epoch(&fx.mls_group_id).await.unwrap(),
        "both members start at the shared epoch N"
    );

    // Alice (admin) commits a routing update and confirms locally (publish-before-
    // apply) → her epoch advances to N+1.
    let commit = fx
        .alice
        .update_circle_relays(&fx.mls_group_id, &["wss://group2.example.com".to_string()])
        .await
        .expect("alice stages a routing commit");
    fx.alice
        .finalize_relay_update(commit.pending, &fx.mls_group_id)
        .await
        .expect("alice finalizes");
    assert_eq!(
        fx.alice.group_epoch(&fx.mls_group_id).await.unwrap(),
        n + 1,
        "alice advances to N+1 on her own confirmed commit"
    );

    // Publish the commit to the shared relay; Bob's engine must receive it via the
    // live-sync loop and converge (ingest → advance_convergence, quiescence=0).
    publish_event(&url, &commit.commit_event).await;

    let mut converged = false;
    for _ in 0..100 {
        if fx.bob.group_epoch(&fx.mls_group_id).await.unwrap() == n + 1 {
            converged = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        converged,
        "Bob's engine must receive Alice's commit over the relay and converge to N+1"
    );

    // Both land on the SAME branch: equal epoch AND cross-decrypt BOTH ways (equal
    // epoch NUMBER alone cannot detect a twin fork — only a shared exporter can).
    assert_eq!(
        fx.alice.group_epoch(&fx.mls_group_id).await.unwrap(),
        fx.bob.group_epoch(&fx.mls_group_id).await.unwrap(),
        "no split-brain: both converge to the same epoch"
    );
    assert!(
        cross_decrypts(
            &fx.alice,
            &fx.alice_keys.public_key(),
            &fx.bob,
            &fx.mls_group_id,
        )
        .await,
        "Bob must decrypt a fresh location Alice sends at the converged epoch"
    );
    assert!(
        cross_decrypts(
            &fx.bob,
            &fx.bob_keys.public_key(),
            &fx.alice,
            &fx.mls_group_id,
        )
        .await,
        "Alice must decrypt a fresh location Bob sends at the converged epoch (bilateral)"
    );

    alice_engine.stop().await;
    bob_engine.stop().await;
}
