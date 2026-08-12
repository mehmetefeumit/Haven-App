//! Security-rule gates that observe the wire, not the type system (Workstream D).
//!
//! Three rules whose coverage was structural where it needed to be
//! observational:
//!
//! * **Rule 11 — kind-445 nonce.** The label half of Rule 11 is a repo guard
//!   (`check_no_exporter_label_override.sh`); the nonce half had nothing. Here
//!   the nonces of a same-epoch burst are read back off the built events —
//!   across a session restart, because a nonce source can be distinct within one
//!   process and identical across launches. The same sample carries Rule 2 (a
//!   fresh ephemeral author key per message).
//! * **Rule 3 — kind-444 welcome stays UNSIGNED.** Asserted on the RAW decrypted
//!   rumor JSON: `nostr::UnsignedEvent` has no `sig` field at all, so peeling
//!   into one silently drops a stray signature and says nothing about the bytes
//!   that were wrapped.
//! * **Rule 5 — exporter retention.** The negative edge (an epoch-N ciphertext
//!   is dead at N+6) is
//!   `mls_e2e_security_tests::p3b_old_epoch_ciphertext_is_undecryptable_after_retention_window`.
//!   Here are the positive edge (it still decrypts at N+5) and the two constants
//!   that place that edge, which until now lived only in comments.

mod helpers;

use std::collections::HashSet;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult, PublishWork};
use haven_core::nostr::mls::{
    app_message_past_epoch_limit, SessionManager, DEFAULT_MAX_PAST_EPOCHS,
};
use nostr::nips::nip44;
use nostr::{Event, JsonUtil as _, Kind, PublicKey};
use serde_json::Value;

use helpers::{
    cleanup_dir, setup_two_party_group, setup_two_party_group_capturing_welcome, TwoPartyGroup,
};

/// A kind-445 `content` is `base64(nonce || ciphertext)` with a 12-byte
/// ChaCha20-Poly1305 nonce (MIP-04 / `transport-nostr-peeler`); the 16-byte AEAD
/// tag puts a floor of 28 decoded bytes under any well-formed event.
const NONCE_LEN: usize = 12;
const MIN_445_CONTENT_LEN: usize = NONCE_LEN + 16;

/// Enough sends per burst that a repeat would show, few enough that they all
/// stay inside ONE epoch — the fixed `group_event_key` Rule 11 forbids a repeat
/// under. Two bursts are taken, either side of a session restart.
const NONCE_SAMPLE: u8 = 32;

// `send_445` / `decrypt_445_content` / `advance_both` are local copies of the
// sibling `mls_e2e_security_tests` harness: each integration test is its own
// crate, so its private items cannot be shared, and `helpers` is compiled into
// every test binary in the directory, none of which need these.

/// Encrypts an inner kind-9 location `content` and returns the publishable 445.
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
///
/// A deliberate near-twin of `mls_e2e_security_tests`'s helper of the same name,
/// NOT a stale copy, and the difference is the point: that file asserts five
/// NEGATIVE outcomes (`is_none()` — cross-group, aged-out epoch, tampered,
/// malformed), so an ingest error there must surface as `None` or the gate it
/// guards cannot be expressed. Every 445 here is one this test just built and
/// sent, so an ingest error is a broken harness rather than a result, and
/// swallowing it into `None` would let the nonce sample silently shrink.
/// Sharing one helper would force one of the two files to lie about what a
/// failure means.
async fn decrypt_445_content(receiver: &SessionManager, event: &Event) -> Option<String> {
    let ingest = receiver
        .process_event(event)
        .await
        .expect("ingest a 445")
        .ingested()
        // Every event here is freshly built, so its NIP-40 expiration is far in
        // the future: a pre-auth rejection would make the gate below pass or
        // fail for a reason that has nothing to do with retention.
        .expect("a freshly-built 445 must reach the engine, not Haven's pre-auth screen");
    let mut results: Vec<LocationMessageResult> = Vec::new();
    results.extend(
        ingest
            .effects
            .events
            .iter()
            .filter_map(SessionManager::location_result_from_event),
    );
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

/// Advances BOTH parties by `count` admin routing commits, so the receiver's tip
/// — the epoch retention is measured against — really moves.
async fn advance_both(g: &TwoPartyGroup, count: u64) {
    for i in 0..count {
        let effects = g
            .alice
            .update_relays(&g.group_id, vec![format!("wss://epoch-{i}.example.com")])
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
        let commit_event =
            SessionManager::transport_message_to_event(&commit).expect("commit → event");
        let ingest = g
            .bob
            .process_event(&commit_event)
            .await
            .expect("bob ingests commit")
            .ingested()
            // Commits carry no `expiration` tag (group history must outlive any
            // TTL), so the receiver-side screen cannot fire here.
            .expect("a commit must reach the engine, not Haven's pre-auth screen");
        for gid in &ingest.effects.pending_convergence {
            g.bob
                .advance_convergence(gid)
                .await
                .expect("bob converges the commit");
        }
    }
}

/// Whether the sample arrives in strictly increasing or strictly decreasing
/// order. Arrays compare lexicographically, i.e. as big-endian integers.
fn is_monotonic(nonces: &[[u8; NONCE_LEN]]) -> bool {
    nonces.windows(2).all(|w| w[0] < w[1]) || nonces.windows(2).all(|w| w[0] > w[1])
}

/// Sends [`NONCE_SAMPLE`] location 445s and appends each one's nonce to
/// `nonces`, checking Rule 2's fresh-ephemeral-author property on the same
/// sample (`authors` accumulates across bursts, so a restart may not reuse one
/// either).
async fn collect_nonce_burst(
    sender: &SessionManager,
    gid: &GroupId,
    identity: PublicKey,
    nonces: &mut Vec<[u8; NONCE_LEN]>,
    authors: &mut HashSet<String>,
) {
    for i in 0..NONCE_SAMPLE {
        let loc = LocationMessage::new(f64::from(i), f64::from(i))
            .to_string()
            .expect("serialize location");
        let event = send_445(sender, gid, &loc).await;

        // Rule 2 rides on the same sample: one fresh ephemeral author per 445.
        assert!(
            authors.insert(event.pubkey.to_hex()),
            "every kind-445 must carry a FRESH ephemeral author key (Rule 2)"
        );
        assert_ne!(
            event.pubkey, identity,
            "the Nostr identity key must never author a kind-445 (Rule 2)"
        );

        let decoded = BASE64
            .decode(&event.content)
            .expect("445 content is base64(nonce || ciphertext)");
        assert!(
            decoded.len() >= MIN_445_CONTENT_LEN,
            "a kind-445 must carry at least a {NONCE_LEN}-byte nonce and a 16-byte AEAD tag, \
             got {} bytes",
            decoded.len()
        );
        nonces.push(
            decoded[..NONCE_LEN]
                .try_into()
                .expect("the leading nonce bytes"),
        );
    }
}

// ============================================================================
// Rule 11 — kind-445 nonce is CSPRNG-random and never repeats under one epoch
// ============================================================================

#[tokio::test]
async fn rule11_kind_445_nonces_never_repeat_under_one_epoch_key() {
    let g = setup_two_party_group("rule11_nonce").await;
    let start_epoch = g.alice.epoch(&g.group_id).await.expect("epoch");
    let identity = g.alice_keys.public_key();

    let mut nonces: Vec<[u8; NONCE_LEN]> = Vec::new();
    let mut ephemeral_authors: HashSet<String> = HashSet::new();
    collect_nonce_burst(
        &g.alice,
        &g.group_id,
        identity,
        &mut nonces,
        &mut ephemeral_authors,
    )
    .await;

    assert_eq!(
        g.alice.epoch(&g.group_id).await.expect("epoch"),
        start_epoch,
        "the whole sample must sit in ONE epoch, or two nonces could repeat under \
         DIFFERENT group_event_keys and the gate below would prove nothing"
    );

    // The sample crosses a PROCESS-lifetime boundary, because the dangerous
    // mutation survives every within-run check: a nonce source that is distinct
    // per run but deterministic across restarts — a `SmallRng::seed_from_u64`
    // with a fixed seed, or a counter behind a per-process-random prefix —
    // repeats its whole sequence on the next launch, and the app restarting
    // does NOT advance the epoch, so that repeat lands under the SAME
    // group_event_key. Rule 11's total break, invisible to a one-session gate.
    let TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir,
        bob_dir,
        group_id,
        ..
    } = g;
    // The Rule-14 LiveSessionGuard releases here, so the reopen below is a
    // legitimate second session over the same on-disk group, not a Rule-14
    // violation.
    drop(alice);
    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys)
        .expect("reopen alice's session on the same MLS database");
    collect_nonce_burst(
        &alice,
        &group_id,
        identity,
        &mut nonces,
        &mut ephemeral_authors,
    )
    .await;

    assert_eq!(
        alice.epoch(&group_id).await.expect("epoch"),
        start_epoch,
        "restarting the app must not advance the epoch — that is exactly why a \
         nonce source that repeats across restarts repeats under ONE key"
    );

    // The UNION of both bursts: a nonce drawn before the restart must not come
    // back after it.
    let distinct: HashSet<[u8; NONCE_LEN]> = nonces.iter().copied().collect();
    assert_eq!(
        distinct.len(),
        nonces.len(),
        "a kind-445 nonce MUST NEVER repeat under a fixed epoch group_event_key (Rule 11)"
    );

    // A fixed-prefix + counter nonce is distinct too, and it leaks the send count
    // and collides across a re-derived prefix. Reject any byte position that never
    // varies: for a CSPRNG that costs p ≈ 256^-63 of a false failure.
    for pos in 0..NONCE_LEN {
        assert!(
            nonces.iter().any(|n| n[pos] != nonces[0][pos]),
            "nonce byte {pos} is identical across all {} sends — that is a fixed prefix, \
             not a CSPRNG draw (Rule 11)",
            nonces.len()
        );
    }
    // ...and reject the counter itself: 64 CSPRNG draws landing in order is 1/64!.
    assert!(
        !is_monotonic(&nonces),
        "the nonces arrive in monotonic order — that is a counter, not a CSPRNG draw (Rule 11)"
    );

    // Deliberately NOT asserted: byte-level uniformity. At this sample size no
    // distribution test can distinguish a CSPRNG from a biased source, so it would
    // buy flakiness and no power.
    cleanup_dir(&alice_dir);
    cleanup_dir(&bob_dir);
}

// ============================================================================
// Rule 3 — the kind-444 welcome rumor reaches the recipient UNSIGNED
// ============================================================================

#[tokio::test]
async fn rule3_welcome_rumor_json_carries_no_signature() {
    let g = setup_two_party_group_capturing_welcome("rule3_unsigned").await;
    let bob_secret = g.group.bob_keys.secret_key();
    let wrap = &g.bob_welcome_gift_wrap;
    assert_eq!(wrap.kind, Kind::GiftWrap, "the welcome ships in a 1059");

    // Peeled by hand rather than through `unwrap_welcome`: that returns an
    // `UnsignedEvent`, whose serde shape has no `sig` field, so it would drop a
    // signature the sender really put on the wire and report Rule 3 as held.
    let seal_json = nip44::decrypt(bob_secret, &wrap.pubkey, &wrap.content)
        .expect("decrypt the 1059 outer layer");
    let seal = Event::from_json(&seal_json).expect("the outer layer holds a seal event");
    assert_eq!(seal.kind, Kind::Seal, "layer 2 is the kind-13 seal");
    seal.verify()
        .expect("the SEAL is signed — Rule 3 constrains the rumor inside it, not this layer");

    let rumor_json =
        nip44::decrypt(bob_secret, &seal.pubkey, &seal.content).expect("decrypt the seal");
    let rumor: Value = serde_json::from_str(&rumor_json).expect("the rumor is JSON");
    let fields = rumor.as_object().expect("the rumor is a JSON object");
    assert_eq!(
        fields.get("kind").and_then(Value::as_u64),
        Some(444),
        "the innermost rumor is the kind-444 welcome"
    );
    assert!(
        !fields.contains_key("sig"),
        "the kind-444 welcome rumor MUST reach the recipient UNSIGNED (Rule 3 / MIP-02): \
         a signed welcome is republishable by anyone who receives it"
    );
    g.cleanup();
}

// ============================================================================
// Rule 5 — exporter-secret retention: the constants, and the positive edge
// ============================================================================

/// Pins the two numbers Rule 5's "5 past epochs" claim rests on, in BOTH
/// directions: widening keeps stale exporter secrets alive, narrowing silently
/// drops legitimate offline backlog.
#[test]
fn rule5_retention_constants_are_pinned() {
    assert_eq!(
        app_message_past_epoch_limit(),
        5,
        "the engine's accept window for a past-epoch application message is Rule 5's bound"
    );
    assert_eq!(
        DEFAULT_MAX_PAST_EPOCHS, 5,
        "the engine retains exactly 5 past epochs' exporter secrets (Rule 5)"
    );
    // The two must agree: a policy that accepts a message older than the epochs
    // whose keys still exist accepts a message it can never decrypt.
    assert_eq!(
        u64::try_from(DEFAULT_MAX_PAST_EPOCHS).expect("retention window fits a u64"),
        app_message_past_epoch_limit(),
        "the accept window must not outrun the exporter secrets that back it"
    );
}

/// The positive edge of the window whose negative edge (N+6) is
/// `mls_e2e_security_tests::p3b_old_epoch_ciphertext_is_undecryptable_after_retention_window`.
/// Without it, retention passing its gate would be indistinguishable from
/// retention of zero epochs.
#[tokio::test]
async fn rule5_epoch_n_ciphertext_still_decrypts_at_the_window_edge() {
    let g = setup_two_party_group("rule5_edge").await;
    let n = g.alice.epoch(&g.group_id).await.expect("epoch");

    let plaintext = LocationMessage::new(51.5074, -0.1278)
        .to_string()
        .expect("serialize location");
    let held = send_445(&g.alice, &g.group_id, &plaintext).await;

    // Driven off the pinned bound, so raising the limit past what the engine
    // keeps keys for fails HERE rather than shipping as a silent drop.
    let window = app_message_past_epoch_limit();
    advance_both(&g, window).await;
    assert_eq!(
        g.bob.epoch(&g.group_id).await.expect("epoch"),
        n + window,
        "bob's tip must sit exactly at the far edge of the retention window"
    );

    let recovered = decrypt_445_content(&g.bob, &held)
        .await
        .expect("a ciphertext exactly at the edge of the retention window must still decrypt");
    assert_eq!(
        recovered, plaintext,
        "the recovered location must be the one sealed {window} epochs ago, byte for byte"
    );
    g.cleanup();
}
