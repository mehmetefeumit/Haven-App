//! MDK v0.10.4 `KeyPackage` and component traps, end to end through Haven's own
//! publish and invite paths.
//!
//! * `KeyPackage::new` / `with_source_event_id` default to the Legacy profile
//!   (MDK `traits/src/engine.rs:60-95`), which every create, invite and
//!   metadata read then refuses; Haven must assert Current wherever it
//!   constructs one.
//! * The lifecycle component 0x800c is mandatory at v0.10.4, and a Current
//!   group requires the identity-proof component 0x8009: a Haven `KeyPackage`
//!   that did not advertise them could neither found nor join a circle.

mod helpers;

use std::collections::BTreeSet;

use haven_core::nostr::mls::types::{KeyPackageAdmission, LocationGroupConfig, ProtocolProfile};
use haven_core::nostr::mls::SessionManager;
use nostr::{EventBuilder, Keys, Kind};

use helpers::{cleanup_dir, create_key_package_event, unique_temp_dir};

/// Every component a Haven circle requires: MDK's defaults (profile 0x8001,
/// admin policy 0x8003, lifecycle 0x800c), Haven's routing 0x8004 and
/// retention 0x8005, and the Current profile's identity proof 0x8009.
const HAVEN_CIRCLE_COMPONENTS: [u16; 6] = [0x8001, 0x8003, 0x8004, 0x8005, 0x8009, 0x800c];

#[tokio::test]
async fn own_key_package_event_builds_after_the_bump() {
    let dir = unique_temp_dir("kp_current_own");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(&dir, &keys).expect("open session");
    // Haven's real publish path; it reads the package back through MDK's
    // metadata parser, which refuses a Legacy-asserted Current package.
    let event =
        create_key_package_event(&session, &keys, &["wss://relay.test.com".to_string()]).await;
    let package = SessionManager::key_package_from_event(&event).expect("parse own package");
    assert_eq!(package.protocol_profile, ProtocolProfile::Current);
    let meta = cgka_engine::key_package_metadata(&package).expect("MDK reads Haven's own package");
    assert_eq!(meta.protocol_profile, ProtocolProfile::Current);
    cleanup_dir(&dir);
}

#[tokio::test]
async fn a_fetched_current_key_package_is_invitable() {
    let alice_dir = unique_temp_dir("kp_current_alice");
    let bob_dir = unique_temp_dir("kp_current_bob");
    let alice_keys = Keys::generate();
    let bob_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys).expect("alice");
    let bob = SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("bob");
    let relays = vec!["wss://relay.test.com".to_string()];
    // What an inviter fetches from a relay: a signed 30443 event.
    let fetched = create_key_package_event(&bob, &bob_keys, &relays).await;

    assert_eq!(
        alice.key_package_admission(&fetched, None).await,
        KeyPackageAdmission::Admissible,
        "MDK's creation admission check accepts it"
    );
    let package = SessionManager::key_package_from_event(&fetched).expect("parse");
    let created = alice
        .create_group(
            vec![package],
            LocationGroupConfig::new("Invitable")
                .with_relay("wss://relay.test.com")
                .with_admin(alice_keys.public_key().to_hex()),
        )
        .await
        .expect("a fetched Current package founds a circle");
    assert!(alice
        .member_pubkeys(&created.group_id)
        .await
        .expect("roster")
        .contains(&bob_keys.public_key().to_hex()));
    cleanup_dir(&alice_dir);
    cleanup_dir(&bob_dir);
}

#[tokio::test]
async fn haven_kp_advertises_800c_and_create_invite_succeed() {
    let dirs = [
        unique_temp_dir("kp_800c_alice"),
        unique_temp_dir("kp_800c_bob"),
        unique_temp_dir("kp_800c_carol"),
    ];
    let keys = [Keys::generate(), Keys::generate(), Keys::generate()];
    let sessions: Vec<SessionManager> = dirs
        .iter()
        .zip(&keys)
        .map(|(dir, k)| SessionManager::new_unencrypted(dir, k).expect("open"))
        .collect();
    let relays = vec!["wss://relay.test.com".to_string()];

    let bob_event = create_key_package_event(&sessions[1], &keys[1], &relays).await;
    let carol_event = create_key_package_event(&sessions[2], &keys[2], &relays).await;
    let meta = cgka_engine::key_package_metadata(
        &SessionManager::key_package_from_event(&bob_event).expect("parse"),
    )
    .expect("metadata");
    let advertised: BTreeSet<u16> = meta.app_components.into_iter().collect();
    for component in HAVEN_CIRCLE_COMPONENTS {
        assert!(
            advertised.contains(&component),
            "a Haven KeyPackage must advertise 0x{component:04x}: {advertised:04x?}"
        );
    }
    for never in [0x8006_u16, 0xF2D1, 0x800b] {
        assert!(
            !advertised.contains(&never),
            "Haven never advertises 0x{never:04x}"
        );
    }

    // Create with one invitee, then invite a second into the existing circle.
    let created = sessions[0]
        .create_group(
            vec![SessionManager::key_package_from_event(&bob_event).expect("parse")],
            LocationGroupConfig::new("Components")
                .with_relay("wss://relay.test.com")
                .with_admin(keys[0].public_key().to_hex()),
        )
        .await
        .expect("create succeeds with the mandatory components");
    assert_eq!(
        sessions[0]
            .key_package_admission(&carol_event, Some(&created.group_id))
            .await,
        KeyPackageAdmission::Admissible
    );
    sessions[0]
        .add_members(
            &created.group_id,
            vec![SessionManager::key_package_from_event(&carol_event).expect("parse")],
        )
        .await
        .expect("an invite into the circle succeeds");
    for dir in &dirs {
        cleanup_dir(dir);
    }
}

#[tokio::test]
async fn new_circle_requires_8001_8003_8004_8005_8009_800c() {
    let alice_dir = unique_temp_dir("kp_required_alice");
    let bob_dir = unique_temp_dir("kp_required_bob");
    let alice_keys = Keys::generate();
    let bob_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys).expect("alice");
    let bob = SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("bob");
    let bob_event =
        create_key_package_event(&bob, &bob_keys, &["wss://relay.test.com".to_string()]).await;

    let created = alice
        .create_group(
            vec![SessionManager::key_package_from_event(&bob_event).expect("parse")],
            LocationGroupConfig::new("Required")
                .with_relay("wss://relay.test.com")
                .with_admin(alice_keys.public_key().to_hex()),
        )
        .await
        .expect("create");
    let required: BTreeSet<u16> = alice
        .group_record(&created.group_id)
        .await
        .expect("group record")
        .required_capabilities
        .app_components
        .ids;
    assert_eq!(
        required,
        HAVEN_CIRCLE_COMPONENTS
            .into_iter()
            .collect::<BTreeSet<u16>>(),
        "a Haven circle requires exactly these components"
    );
    cleanup_dir(&alice_dir);
    cleanup_dir(&bob_dir);
}

#[tokio::test]
async fn a_pre_migration_or_foreign_key_package_is_never_invitable() {
    let alice_dir = unique_temp_dir("kp_admission_alice");
    let bob_dir = unique_temp_dir("kp_admission_bob");
    let alice_keys = Keys::generate();
    let bob_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys).expect("alice");
    let bob = SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("bob");
    let fetched =
        create_key_package_event(&bob, &bob_keys, &["wss://relay.test.com".to_string()]).await;
    let resigned = |kind: u16, content: &str| {
        EventBuilder::new(Kind::Custom(kind), content)
            .tags(fetched.tags.clone())
            .sign_with_keys(&bob_keys)
            .expect("sign")
    };

    assert_eq!(
        alice
            .key_package_admission(&resigned(443, &fetched.content), None)
            .await,
        KeyPackageAdmission::NeedsUpdate,
        "a kind-443 KeyPackage is a peer still on a pre-migration build"
    );
    assert_eq!(
        alice
            .key_package_admission(&resigned(1, &fetched.content), None)
            .await,
        KeyPackageAdmission::Unusable,
        "a KeyPackage under any other kind is not one"
    );
    assert_eq!(
        alice
            .key_package_admission(&resigned(30443, "not a key package"), None)
            .await,
        KeyPackageAdmission::Unusable,
        "a 30443 that does not decode is offered a retry, not an update prompt"
    );
    cleanup_dir(&alice_dir);
    cleanup_dir(&bob_dir);
}
