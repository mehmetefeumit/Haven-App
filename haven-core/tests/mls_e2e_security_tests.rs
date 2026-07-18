//! MLS end-to-end SECURITY GATES over the Dark Matter engine (DM-5a).
//!
//! Re-expresses Haven's security black-box gates on the new `SessionManager`
//! stack (security F2/F9): key separation (Rule 1), ephemeral-445 uniqueness
//! (Rule 2), 444-unsigned (Rule 3), group-id privacy (Rule 4), exporter retention
//! (Rule 5), error redaction (Rule 6). Where the pre-migration mechanism is
//! genuinely gone (per-send NIP-40 expiration; the `get_ratchet_tree_info` leaf
//! walk; a public per-past-epoch exporter query) the SUBJECT deletion or an
//! honest NARROWING is documented at the site — never a silently weakened gate.

mod helpers;

use haven_core::location::LocationMessage;
use haven_core::nostr::giftwrap::unwrap_welcome;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult, PublishWork};
use haven_core::nostr::mls::{redact_hex_sequences, SessionManager};
use nostr::{Event, EventBuilder, JsonUtil, Keys, Kind, Timestamp};

use helpers::{
    assert_no_raw_mls_group_id_leak, setup_two_party_group,
    setup_two_party_group_capturing_welcome, TwoPartyGroup,
};

/// Runs an async future on a fresh current-thread runtime (the giftwrap peel is
/// async; a couple of tests here are otherwise synchronous asserts).
fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
        .block_on(fut)
}

/// Encrypts an inner kind-9 location `content` from `sender` and returns the
/// publishable kind-445 transport event.
async fn send_445(sender: &SessionManager, gid: &GroupId, content: &str) -> Event {
    let effects = sender
        .send_location(gid, content.to_string())
        .await
        .expect("send location");
    let msg = effects
        .publish
        .iter()
        .find_map(|w| match w {
            PublishWork::ApplicationMessage { msg } => Some(msg.clone()),
            _ => None,
        })
        .expect("application message publish work");
    SessionManager::transport_message_to_event(&msg).expect("transport → event")
}

/// The inner location content a receiver recovers from a 445, or `None`.
async fn decrypt_445_content(receiver: &SessionManager, event: &Event) -> Option<String> {
    let ingest = receiver.process_event(event).await.ok()?;
    let mut results: Vec<LocationMessageResult> = ingest
        .effects
        .events
        .iter()
        .filter_map(SessionManager::location_result_from_event)
        .collect();
    for gid in &ingest.effects.pending_convergence {
        if let Ok(more) = receiver.advance_convergence(gid).await {
            results.extend(
                more.events
                    .iter()
                    .filter_map(SessionManager::location_result_from_event),
            );
        }
    }
    results.into_iter().find_map(|r| match r {
        LocationMessageResult::Location { content, .. } => Some(content),
        _ => None,
    })
}

/// Advances a two-party group by `count` admin (routing) commits, converging both
/// Alice and Bob, so both reach epoch N+`count`.
async fn advance_both(g: &TwoPartyGroup, count: usize) {
    for i in 0..count {
        let relay = format!("wss://epoch-{i}.example.com");
        let effects = g
            .alice
            .update_relays(&g.group_id, vec![relay])
            .await
            .expect("alice routing commit");
        let (commit, pending) = effects
            .publish
            .iter()
            .find_map(|w| match w {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("group evolution");
        g.alice
            .confirm_published(pending)
            .await
            .expect("alice confirms");
        let commit_event = SessionManager::transport_message_to_event(&commit).unwrap();
        let ingest = g
            .bob
            .process_event(&commit_event)
            .await
            .expect("bob ingests commit");
        for gid in &ingest.effects.pending_convergence {
            let _ = g.bob.advance_convergence(gid).await;
        }
    }
}

// ============================================================================
// G1 — harness validity
// ============================================================================

#[tokio::test]
async fn g1_test_harness_creates_valid_group() {
    let g = setup_two_party_group("g1_harness").await;
    let alice_members = g.alice.member_pubkeys(&g.group_id).await.unwrap();
    assert_eq!(alice_members.len(), 2, "group has 2 members");
    assert!(alice_members.contains(&g.alice_keys.public_key().to_hex()));
    assert!(alice_members.contains(&g.bob_keys.public_key().to_hex()));

    let (alice_ng, _) = g.alice.group_routing(&g.group_id).await.unwrap();
    let (bob_ng, _) = g.bob.group_routing(&g.group_id).await.unwrap();
    assert_eq!(alice_ng, bob_ng, "both sides agree on the nostr_group_id");
    g.cleanup();
}

// ============================================================================
// G2 — encryption roundtrip
// ============================================================================

#[tokio::test]
async fn g2_location_encryption_roundtrip() {
    let g = setup_two_party_group("g2_roundtrip").await;
    let loc = LocationMessage::new(37.7749, -122.4194)
        .to_string()
        .unwrap();
    let event = send_445(&g.alice, &g.group_id, &loc).await;
    assert_eq!(event.kind, Kind::Custom(445), "outer event is kind 445");
    assert!(
        !event.content.contains("37.77"),
        "445 content must be ciphertext"
    );

    let recovered = decrypt_445_content(&g.bob, &event)
        .await
        .expect("bob decrypts");
    let decoded = LocationMessage::from_string(&recovered).unwrap();
    assert!((decoded.latitude - 37.7749).abs() < 1e-9);
    g.cleanup();
}

#[tokio::test]
async fn g2_bidirectional_messaging_works() {
    let g = setup_two_party_group("g2_bidir").await;
    let a = LocationMessage::new(1.0, 2.0).to_string().unwrap();
    let ea = send_445(&g.alice, &g.group_id, &a).await;
    assert!(
        decrypt_445_content(&g.bob, &ea).await.is_some(),
        "bob decrypts alice"
    );
    let b = LocationMessage::new(3.0, 4.0).to_string().unwrap();
    let eb = send_445(&g.bob, &g.group_id, &b).await;
    assert!(
        decrypt_445_content(&g.alice, &eb).await.is_some(),
        "alice decrypts bob"
    );
    g.cleanup();
}

// DELETED-WITH-SUBJECT: `outer_kind_445_carries_expiration_tag_when_requested` —
// per-send NIP-40 expiration is dropped (retention is a group-level
// `message-retention.v1` component now, not a per-message tag).

// ============================================================================
// G3 / RM7 — cross-group isolation (distinct ids + exporter secrets)
// ============================================================================

#[tokio::test]
async fn g3_cross_group_decryption_fails() {
    let g1 = setup_two_party_group("g3_group1").await;
    let g2 = setup_two_party_group("g3_group2").await;

    let loc = LocationMessage::new(10.0, 20.0).to_string().unwrap();
    let event = send_445(&g1.alice, &g1.group_id, &loc).await;
    assert!(
        decrypt_445_content(&g2.bob, &event).await.is_none(),
        "a message from group 1 must NOT decrypt for group 2 (cross-group isolation)"
    );
    g1.cleanup();
    g2.cleanup();
}

#[tokio::test]
async fn rm7_independent_groups_have_distinct_ids() {
    let g1 = setup_two_party_group("rm7_g1").await;
    let g2 = setup_two_party_group("rm7_g2").await;
    let (n1, _) = g1.alice.group_routing(&g1.group_id).await.unwrap();
    let (n2, _) = g2.alice.group_routing(&g2.group_id).await.unwrap();
    assert_ne!(
        n1, n2,
        "independent groups get distinct random nostr_group_ids"
    );
    assert_ne!(
        g1.group_id.as_slice(),
        g2.group_id.as_slice(),
        "independent groups have distinct MLS group ids"
    );
    g1.cleanup();
    g2.cleanup();
}

// ============================================================================
// G4 — ephemeral-445 uniqueness + ≠ identity (Rule 2)
// ============================================================================

#[tokio::test]
async fn g4_unique_ephemeral_pubkeys_per_message() {
    let g = setup_two_party_group("g4_unique").await;
    let mut seen = std::collections::HashSet::new();
    for i in 0..8 {
        let loc = LocationMessage::new(f64::from(i), f64::from(i))
            .to_string()
            .unwrap();
        let event = send_445(&g.alice, &g.group_id, &loc).await;
        assert!(
            seen.insert(event.pubkey.to_hex()),
            "every kind-445 must carry a FRESH ephemeral pubkey (Rule 2)"
        );
    }
    g.cleanup();
}

#[tokio::test]
async fn g4_ephemeral_pubkey_differs_from_sender_identity() {
    let g = setup_two_party_group("g4_differs").await;
    let loc = LocationMessage::new(5.0, 6.0).to_string().unwrap();
    let event = send_445(&g.alice, &g.group_id, &loc).await;
    assert_ne!(
        event.pubkey,
        g.alice_keys.public_key(),
        "the 445 ephemeral pubkey MUST differ from the sender's Nostr identity key (Rule 2)"
    );
    g.cleanup();
}

// ============================================================================
// Rule 4 — group-id privacy (h tag = nostr_group_id, never the MLS GroupId)
// ============================================================================

#[tokio::test]
async fn encrypted_event_has_h_tag_with_nostr_group_id_only() {
    let g = setup_two_party_group("h_tag").await;
    let (nostr_group_id, _) = g.alice.group_routing(&g.group_id).await.unwrap();
    let loc = LocationMessage::new(1.0, 2.0).to_string().unwrap();
    let event = send_445(&g.alice, &g.group_id, &loc).await;
    assert_no_raw_mls_group_id_leak(&event, g.group_id.as_slice(), &nostr_group_id);
    g.cleanup();
}

// ============================================================================
// Rule 1 — key separation (MLS sig key ≠ Nostr identity key)
// ============================================================================

/// P3a (Rule 1, RE-EXPRESSED with an honest NARROWING).
///
/// The pre-migration gate walked the ratchet tree (`get_ratchet_tree_info`) to
/// read the leaf signature key and assert it ≠ the Nostr identity key. That API
/// is gone, and Haven no longer deps `openmls` directly, so the leaf signature
/// key cannot be byte-extracted from an integration test. Key separation is now
/// formalized ON-WIRE as the mandatory `account-identity-proof.v2` leaf extension
/// (W7): the engine REJECTS any leaf whose proof does not verify. The observable
/// re-expression: (1) a genuine Haven KeyPackage — created with the identity key —
/// is ACCEPTED by `create_group` (the two-party setup succeeds), so its
/// identity-proof is present + verifies; and (2) the Nostr identity key is NEVER
/// used to sign a kind-445 group message (an ephemeral key is), so the identity
/// key and the MLS message-signing key are distinct on every group message.
#[tokio::test]
async fn p3a_key_separation_identity_proof_enforced_and_identity_not_used_for_group_messages() {
    let g = setup_two_party_group("p3a_keysep").await;
    assert_eq!(g.alice.member_pubkeys(&g.group_id).await.unwrap().len(), 2);

    let loc = LocationMessage::new(9.0, 9.0).to_string().unwrap();
    let event = send_445(&g.alice, &g.group_id, &loc).await;
    assert_ne!(
        event.pubkey,
        g.alice_keys.public_key(),
        "the Nostr identity key must never sign a kind-445 group message (key separation)"
    );
    event
        .verify()
        .expect("445 must be validly signed by its ephemeral key");
    g.cleanup();
}

// ============================================================================
// Rule 3 — 444 welcome rumor is UNSIGNED
// ============================================================================

#[tokio::test]
async fn rm1_welcome_rumor_is_unsigned_kind_444() {
    let g = setup_two_party_group_capturing_welcome("rm1_unsigned").await;
    // Peel the engine-produced 1059 gift wrap addressed to Bob; the inner welcome
    // rumor is returned as an `UnsignedEvent` (unsigned BY TYPE) and its kind is
    // validated as 444 by `unwrap_welcome` (Rule 3: only the 1059 seal is signed).
    let unwrapped = unwrap_welcome(&g.group.bob_keys, &g.bob_welcome_gift_wrap)
        .await
        .expect("peel the 1059 welcome gift wrap");
    assert_eq!(
        unwrapped.rumor.kind,
        Kind::Custom(444),
        "the welcome rumor must be kind 444"
    );
    g.group.cleanup();
}

#[tokio::test]
async fn rm1b_welcome_gift_wrap_does_not_leak_raw_mls_group_id() {
    let g = setup_two_party_group_capturing_welcome("rm1b_leak").await;
    let raw_mls_hex = hex::encode(g.group.group_id.as_slice());
    let json = g.bob_welcome_gift_wrap.as_json();
    assert!(
        !json.contains(&raw_mls_hex),
        "the raw MLS group id must NOT appear in the relay-visible 1059 gift wrap"
    );
    g.group.cleanup();
}

// ============================================================================
// Rule 5 — exporter retention (DEFAULT_MAX_PAST_EPOCHS = 5)
// ============================================================================

/// P3b / RM8 (Rule 5, RE-EXPRESSED with an honest NARROWING).
///
/// The engine retains exactly `DEFAULT_MAX_PAST_EPOCHS = 5` past epochs' exporter
/// secrets (`wire_format.rs:38`; Haven does not override it). There is no PUBLIC
/// per-past-epoch exporter query, so the retention is asserted through the only
/// observable it governs: a kind-445 sealed with an OLD epoch's exporter secret is
/// UNDECRYPTABLE once the receiver advances more than 5 epochs past it, while a
/// message within the window still decrypts (the baseline below).
#[tokio::test]
async fn p3b_old_epoch_ciphertext_is_undecryptable_after_retention_window() {
    let g = setup_two_party_group("p3b_prune").await;
    let n = g.alice.epoch(&g.group_id).await.unwrap();

    // A message sealed at epoch N, decryptable within the window (baseline).
    let within = LocationMessage::new(12.0, 34.0).to_string().unwrap();
    let within_event = send_445(&g.alice, &g.group_id, &within).await;
    assert!(
        decrypt_445_content(&g.bob, &within_event).await.is_some(),
        "a same-epoch message decrypts within the retention window (baseline)"
    );

    // Alice seals a SECOND message at N; hold it (Bob never sees it at N).
    let held = LocationMessage::new(56.0, 78.0).to_string().unwrap();
    let held_event = send_445(&g.alice, &g.group_id, &held).await;

    // Advance BOTH parties 6 epochs (> the 5-past-epoch window) past N.
    advance_both(&g, 6).await;
    assert!(
        g.bob.epoch(&g.group_id).await.unwrap() >= n + 6,
        "both parties advanced beyond the 5-epoch retention window"
    );

    // The held epoch-N ciphertext must NOT yield plaintext to Bob at N+6: the N
    // exporter secret aged out of the 5-epoch window.
    assert!(
        decrypt_445_content(&g.bob, &held_event).await.is_none(),
        "a ciphertext from an epoch older than the 5-epoch retention window must not \
         yield plaintext after the window closes"
    );
    g.cleanup();
}

// ============================================================================
// RM2 / RM6 — tampered / malformed ciphertext fails safely
// ============================================================================

#[tokio::test]
async fn rm2_tampered_ciphertext_does_not_yield_plaintext() {
    let g = setup_two_party_group("rm2_tamper").await;
    let loc = LocationMessage::new(1.0, 2.0).to_string().unwrap();
    let event = send_445(&g.alice, &g.group_id, &loc).await;

    // A well-formed but corrupt 445: same #h, garbage content, fresh ephemeral sig.
    let tampered = EventBuilder::new(Kind::Custom(445), "dGFtcGVyZWQtY2lwaGVydGV4dA==")
        .tags(event.tags.to_vec())
        .sign_with_keys(&Keys::generate())
        .unwrap();
    assert!(
        decrypt_445_content(&g.bob, &tampered).await.is_none(),
        "a tampered kind-445 must never yield plaintext"
    );
    g.cleanup();
}

#[tokio::test]
async fn rm6_malformed_events_fail_gracefully() {
    let g = setup_two_party_group("rm6_malformed").await;
    let (nostr_group_id, _) = g.alice.group_routing(&g.group_id).await.unwrap();
    let h = hex::encode(nostr_group_id);
    let big = "A".repeat(200_000);

    for content in ["", "!!!not-base64!!!", big.as_str()] {
        let ev = EventBuilder::new(Kind::Custom(445), content)
            .tags([nostr::Tag::parse(["h", &h]).unwrap()])
            .sign_with_keys(&Keys::generate())
            .unwrap();
        // Either a hard error or a non-Location outcome — never plaintext, never panic.
        let _ = g.bob.process_event(&ev).await;
        assert!(decrypt_445_content(&g.bob, &ev).await.is_none());
    }
    g.cleanup();
}

// ============================================================================
// Rule 6 — error redaction (no group-id hex in a boundary error Display)
// ============================================================================

#[test]
fn rm_error_redaction_strips_group_id_hex() {
    // Rule 6/8: the boundary redactor removes any long hex run (≥16 hex chars —
    // the class a raw MLS GroupId / exporter material falls into) from an error
    // string surfaced at the FFI / `CircleError` / `NostrError` boundary, over the
    // new EngineError/PeelerError text as much as any other (#864-class strings
    // that embed full group-id hex).
    let raw = "ingest failed for group 0123456789abcdef0123456789abcdef while decrypting";
    let redacted = redact_hex_sequences(raw);
    assert!(
        !redacted.contains("0123456789abcdef0123456789abcdef"),
        "a group-id-length hex run must be redacted from a boundary error"
    );
    assert!(
        redacted.contains("ingest failed"),
        "non-hex prose is preserved"
    );
    // A short hex-ish token (< 16) is NOT a group id and is left intact.
    let short = redact_hex_sequences("epoch abc123 advanced");
    assert!(
        short.contains("abc123"),
        "short tokens are not over-redacted"
    );
}

/// Belt-and-suspenders privacy sweep over ALL relay-visible welcome bytes.
#[test]
fn rm_welcome_gift_wrap_privacy_sweep() {
    let g = block_on(setup_two_party_group_capturing_welcome("rm_sweep"));
    let raw_mls_hex = hex::encode(g.group.group_id.as_slice());
    assert!(
        !g.bob_welcome_gift_wrap.as_json().contains(&raw_mls_hex),
        "no relay-visible welcome byte may carry the raw MLS group id"
    );
    g.group.cleanup();
}

// ============================================================================
// KeyPackage kind (30443)
// ============================================================================

#[tokio::test]
async fn key_package_event_is_valid_kind_30443() {
    use helpers::create_key_package_event;
    let dir = helpers::unique_temp_dir("kp_kind");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(&dir, &keys).unwrap();
    let event =
        create_key_package_event(&session, &keys, &["wss://relay.test.com".to_string()]).await;
    assert_eq!(
        event.kind.as_u16(),
        30443,
        "KeyPackage event is kind 30443 (W1)"
    );
    assert_eq!(
        event.pubkey,
        keys.public_key(),
        "signed by the identity key"
    );
    event.verify().expect("valid signature");
    assert!(event.created_at <= Timestamp::now());
    helpers::cleanup_dir(&dir);
}
