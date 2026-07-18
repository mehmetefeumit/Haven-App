//! Dark Matter two-party harness smoke test (DM-5a).
//!
//! Validates the migrated `helpers::setup_two_party_group` harness end-to-end
//! over the new `SessionManager` stack: Alice creates a group with Bob's
//! kind-30443 KeyPackage, Bob joins via the engine-produced 1059 welcome, a
//! location round-trips (Alice → Bob), and an admin `update_relays` commit
//! advances the epoch. This is the integration-level counterpart to the inline
//! `CircleManager` two-party idiom proven in `src/circle/manager.rs`.

mod helpers;

use haven_core::nostr::mls::types::IngestOutcome;
use haven_core::nostr::mls::SessionManager;

#[tokio::test]
async fn two_party_group_setup_joins_bob() {
    let g = helpers::setup_two_party_group("smoke_join").await;

    // Both parties agree on the roster (Alice + Bob).
    let alice_members = g.alice.member_pubkeys(&g.group_id).await.unwrap();
    let bob_members = g.bob.member_pubkeys(&g.group_id).await.unwrap();
    assert_eq!(alice_members.len(), 2);
    assert_eq!(bob_members.len(), 2);
    assert_eq!(
        g.alice.epoch(&g.group_id).await.unwrap(),
        g.bob.epoch(&g.group_id).await.unwrap()
    );

    g.cleanup();
}

#[tokio::test]
async fn two_party_location_round_trips_alice_to_bob() {
    let g = helpers::setup_two_party_group("smoke_loc").await;

    // Alice sends a location; convert the transport message to a wire event.
    let effects = g
        .alice
        .send_location(
            &g.group_id,
            r#"{"latitude":51.5,"longitude":-0.12}"#.to_string(),
        )
        .await
        .unwrap();
    let app = effects
        .publish
        .iter()
        .find_map(|w| match w {
            haven_core::nostr::mls::types::PublishWork::ApplicationMessage { msg } => Some(msg),
            _ => None,
        })
        .expect("application message");
    let event = SessionManager::transport_message_to_event(app).unwrap();

    // Bob ingests it; a location application message applies immediately.
    let ingest = g.bob.process_event(&event).await.unwrap();
    assert!(matches!(ingest.outcome, IngestOutcome::Processed));
    let senders = helpers::location_senders(&ingest.effects.events);
    assert_eq!(senders, vec![g.alice_keys.public_key().to_hex()]);

    g.cleanup();
}

#[tokio::test]
async fn admin_relay_update_advances_epoch() {
    let g = helpers::setup_two_party_group("smoke_epoch").await;
    let start = g.alice.epoch(&g.group_id).await.unwrap();
    // Alice is the admin; advance three epochs via routing commits.
    let reached = helpers::advance_epoch_to_at_least(&g.alice, &g.group_id, start + 3, 10).await;
    assert!(reached >= start + 3);
    g.cleanup();
}
