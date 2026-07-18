//! Reusable test helpers for the Dark Matter MLS integration tests.
//!
//! These helpers drive REAL MLS crypto over `SessionManager::new_unencrypted()`
//! storage. Each `SessionManager` instance simulates a separate device with its
//! own hydrated `AccountDeviceSession`. No mocking is needed.
//!
//! # Dark Matter port (DM-5a)
//!
//! The pre-migration helpers built on the deleted `MdkManager` (sync, interior
//! mutable). The engine is now `async` + `&mut`, so every group op is `async`.
//! The two-party fixture is two in-memory-ish `SessionManager`s: Bob mints a
//! kind-30443 `KeyPackage` event, Alice creates the group with it and confirms
//! the pending create (publish-before-apply), and Bob ingests the engine-produced
//! gift-wrapped (1059) welcome to join. `create_key_package` /
//! `merge_pending_commit` / `process_welcome` / `accept_welcome` /
//! `get_pending_welcomes` are gone; the flow below is their re-expression.
//!
//! Each integration test binary compiles this module independently and only uses
//! a subset of the helpers, so `dead_code` is silenced at the module level.

#![allow(dead_code)]

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::nostr::mls::types::{
    GroupEvent, GroupId, LocationGroupConfig, PendingStateRef, PublishWork, SessionEffects,
    TransportMessage,
};
use haven_core::nostr::mls::SessionManager;
use haven_core::nostr::NostrError;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, JsonUtil as _, Keys};

/// Atomic counter for unique test directory names.
static HELPER_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Creates a unique temporary directory for test isolation.
pub fn unique_temp_dir(prefix: &str) -> PathBuf {
    let id = HELPER_COUNTER.fetch_add(1, Ordering::SeqCst);
    env::temp_dir().join(format!(
        "haven_g_test_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ))
}

/// Removes a temporary test directory. Ignores errors silently.
pub fn cleanup_dir(dir: &PathBuf) {
    let _ = std::fs::remove_dir_all(dir);
}

/// Mints a signed kind-30443 `KeyPackage` event for a device.
///
/// Uses the DM-2b maintenance builder — the real publish path — so a party's
/// `KeyPackage` is produced exactly as in production. The event `content` is
/// base64 of the TLS-serialized MLS `KeyPackage`; `SessionManager` parses it back
/// via [`SessionManager::key_package_from_event`].
pub async fn create_key_package_event(
    session: &SessionManager,
    keys: &Keys,
    relays: &[String],
) -> Event {
    build_kp_maintenance_events(session, keys, relays, None)
        .await
        .expect("build key package event")
        .event
}

/// Extracts the sole `GroupCreated { welcomes, pending }` from create effects.
fn take_group_created(effects: &SessionEffects) -> (Vec<TransportMessage>, PendingStateRef) {
    for work in &effects.publish {
        if let PublishWork::GroupCreated { welcomes, pending } = work {
            return (welcomes.clone(), *pending);
        }
    }
    panic!("create_group produced no GroupCreated publish work");
}

/// Result of setting up a two-party MLS group.
pub struct TwoPartyGroup {
    pub alice: SessionManager,
    pub alice_keys: Keys,
    pub alice_dir: PathBuf,
    pub bob: SessionManager,
    pub bob_keys: Keys,
    pub bob_dir: PathBuf,
    pub group_id: GroupId,
    pub nostr_group_id: [u8; 32],
}

impl TwoPartyGroup {
    /// Cleans up all temporary directories.
    pub fn cleanup(&self) {
        cleanup_dir(&self.alice_dir);
        cleanup_dir(&self.bob_dir);
    }
}

/// Sets up a complete two-party MLS group (Alice creates, Bob joins).
///
/// 1. Creates separate `SessionManager`s for Alice and Bob.
/// 2. Bob mints a kind-30443 `KeyPackage` event.
/// 3. Alice creates the group with Bob's `KeyPackage` and confirms the pending
///    create (publish-before-apply).
/// 4. Bob ingests the engine-produced gift-wrapped (1059) welcome to join.
pub async fn setup_two_party_group(prefix: &str) -> TwoPartyGroup {
    let relays = vec!["wss://relay.test.com".to_string()];

    let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
    let alice_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys)
        .expect("should create alice session");

    let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
    let bob_keys = Keys::generate();
    let bob =
        SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("should create bob session");

    let bob_kp_event = create_key_package_event(&bob, &bob_keys, &relays).await;
    let bob_kp = SessionManager::key_package_from_event(&bob_kp_event).expect("parse bob kp");

    let config = LocationGroupConfig::new("Test Group")
        .with_description("Integration test group")
        .with_relay("wss://relay.test.com")
        .with_admin(alice_keys.public_key().to_hex());

    let created = alice
        .create_group(vec![bob_kp], config)
        .await
        .expect("should create group");
    let group_id = created.group_id.clone();
    let (nostr_group_id, _) = alice.group_routing(&group_id).await.expect("routing");

    let (welcomes, pending) = take_group_created(&created.effects);
    // Confirm the pending create so Alice's group is Stable at the created epoch.
    alice
        .confirm_published(pending)
        .await
        .expect("confirm create");

    // Bob joins by ingesting the (still-encrypted) gift-wrapped welcome.
    let welcome_event =
        SessionManager::transport_message_to_event(&welcomes[0]).expect("welcome to event");
    bob.accept_welcome(&welcome_event)
        .await
        .expect("bob accepts welcome");

    TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir,
        bob,
        bob_keys,
        bob_dir,
        group_id,
        nostr_group_id,
    }
}

/// A two-party group plus the gift-wrapped (1059) welcome Bob ingested to join.
///
/// Used by tests that need to inspect the welcome delivery itself. Under the DM
/// stack Haven only ever sees the outer 1059 gift wrap; the inner unsigned
/// kind-444 rumor is peeled inside the engine (the MIP-02 unsigned-444 invariant
/// is re-expressed as a black-box gate in `mls_e2e_security_tests`).
pub struct TwoPartyGroupWithWelcome {
    pub group: TwoPartyGroup,
    /// The kind-1059 gift wrap the engine produced for Bob during creation.
    pub bob_welcome_gift_wrap: Event,
}

impl TwoPartyGroupWithWelcome {
    pub fn cleanup(&self) {
        self.group.cleanup();
    }
}

/// Like [`setup_two_party_group`] but also returns the 1059 gift wrap Bob joined
/// through, so tests can assert protocol properties of the welcome delivery.
pub async fn setup_two_party_group_capturing_welcome(prefix: &str) -> TwoPartyGroupWithWelcome {
    let relays = vec!["wss://relay.test.com".to_string()];

    let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
    let alice_keys = Keys::generate();
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys)
        .expect("should create alice session");

    let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
    let bob_keys = Keys::generate();
    let bob =
        SessionManager::new_unencrypted(&bob_dir, &bob_keys).expect("should create bob session");

    let bob_kp_event = create_key_package_event(&bob, &bob_keys, &relays).await;
    let bob_kp = SessionManager::key_package_from_event(&bob_kp_event).expect("parse bob kp");

    let config = LocationGroupConfig::new("Test Group")
        .with_description("Integration test group")
        .with_relay("wss://relay.test.com")
        .with_admin(alice_keys.public_key().to_hex());

    let created = alice
        .create_group(vec![bob_kp], config)
        .await
        .expect("should create group");
    let group_id = created.group_id.clone();
    let (nostr_group_id, _) = alice.group_routing(&group_id).await.expect("routing");

    let (welcomes, _pending) = take_group_created(&created.effects);
    for work in &created.effects.publish {
        if let PublishWork::GroupCreated { pending, .. } = work {
            alice
                .confirm_published(*pending)
                .await
                .expect("confirm create");
        }
    }

    let welcome_event =
        SessionManager::transport_message_to_event(&welcomes[0]).expect("welcome to event");
    bob.accept_welcome(&welcome_event)
        .await
        .expect("bob accepts welcome");

    TwoPartyGroupWithWelcome {
        group: TwoPartyGroup {
            alice,
            alice_keys,
            alice_dir,
            bob,
            bob_keys,
            bob_dir,
            group_id,
            nostr_group_id,
        },
        bob_welcome_gift_wrap: welcome_event,
    }
}

/// Drives `session`'s view of `group_id` forward to at least `target_epoch`.
///
/// DM re-expression of the deleted `self_update` ritual: the engine has no
/// `self_update`, so the epoch is advanced with real admin `update_relays`
/// (`UpdateAppComponents(nostr-routing.v1)`) commits — each is a genuine commit
/// that advances the epoch by one on confirm, WITHOUT changing membership. The
/// caller MUST be an admin of `group_id`. Alternates the relay set each round so
/// no commit is a no-op. Returns the epoch reached.
pub async fn advance_epoch_to_at_least(
    session: &SessionManager,
    group_id: &GroupId,
    target_epoch: u64,
    max_iters: usize,
) -> u64 {
    let mut epoch = session.epoch(group_id).await.expect("epoch");
    for i in 0..max_iters {
        if epoch >= target_epoch {
            break;
        }
        // Two distinct valid relay sets, alternated, so each update is a real
        // routing change (never a rejected no-op).
        let relays = if i % 2 == 0 {
            vec!["wss://relay-a.test.com".to_string()]
        } else {
            vec!["wss://relay-b.test.com".to_string()]
        };
        let effects = session
            .update_relays(group_id, relays)
            .await
            .expect("update_relays should advance the epoch");
        for work in &effects.publish {
            if let PublishWork::GroupEvolution { pending, .. } = work {
                session
                    .confirm_published(*pending)
                    .await
                    .expect("confirm relay-update commit");
            }
        }
        epoch = session.epoch(group_id).await.expect("epoch");
    }
    assert!(
        epoch >= target_epoch,
        "epoch did not advance to target within the safety cap (reached={epoch}, \
         target={target_epoch})"
    );
    epoch
}

/// Asserts a `NostrError` is a genuine MLS decryption/processing failure and NOT
/// a "group not found" error.
///
/// DM note: the engine redacts hex sequences in error strings (Rule 6/8) and its
/// decrypt-failure taxonomy differs from old MDK, so this checks the surviving
/// distinction — a `MdkError` that is not a group-not-found — rather than the old
/// substring set.
pub fn assert_is_decryption_failure(err: &NostrError, context: &str) {
    match err {
        NostrError::MdkError(msg) => {
            let lower = msg.to_lowercase();
            assert!(
                !lower.contains("group not found") && !lower.contains("unknown group"),
                "{context}: failure must be a decryption/processing error, not \
                 group-not-found (got MdkError: {msg:?})"
            );
        }
        NostrError::Decryption(_) | NostrError::InvalidEvent(_) => {}
        other => {
            panic!("{context}: expected a decryption/processing error, got {other:?}")
        }
    }
}

/// Asserts a published kind:445 `event` leaks NO raw MLS group ID — not in any
/// tag, not anywhere in the serialized JSON — while the privacy-preserving
/// `expected_nostr_group_id` IS present (Rule 4 / Security Rule #4).
pub fn assert_no_raw_mls_group_id_leak(
    event: &Event,
    raw_mls_group_id: &[u8],
    expected_nostr_group_id: &[u8],
) {
    let raw_mls_hex = hex::encode(raw_mls_group_id);
    let nostr_hex = hex::encode(expected_nostr_group_id);
    assert_ne!(
        nostr_hex, raw_mls_hex,
        "nostr_group_id must differ from the raw MLS group ID for the scan to be meaningful"
    );

    let json = event.as_json();
    assert!(
        !json.contains(&raw_mls_hex),
        "raw MLS group ID must NOT appear anywhere in the kind:445 event JSON"
    );
    for tag in event.tags.iter() {
        for part in tag.as_slice() {
            assert!(
                !part.contains(&raw_mls_hex),
                "raw MLS group ID must NOT appear in any tag of a kind:445 event"
            );
        }
    }
    assert!(
        json.contains(&nostr_hex),
        "the privacy-preserving nostr_group_id should appear in the kind:445 event"
    );
}

/// Convenience: fold a batch of engine [`GroupEvent`]s into the sender pubkeys of
/// any received location messages (hex), for delivery assertions.
pub fn location_senders(events: &[GroupEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            GroupEvent::MessageReceived { sender, .. } => Some(hex::encode(sender.as_slice())),
            _ => None,
        })
        .collect()
}
