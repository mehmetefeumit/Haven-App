//! A receiver that misses too many consecutive messages from one peer goes
//! permanently deaf to that peer — and a commit is what gets it hearing again.
//!
//! # The failure (C4)
//!
//! `OpenMLS` keeps a per-sender decryption ratchet and refuses to wind it further
//! than `SenderRatchetConfiguration::maximum_forward_distance` past its head
//! (`sender_ratchet.rs::secret_for_decryption` → `TooDistantInTheFuture`). A
//! ratchet cannot be rewound, and a Haven circle's epoch only moves when its
//! membership changes, so once a member has missed more than that many
//! application messages from one peer, **every** later message from that peer
//! fails forever. At the worst cadence Haven publishes (one fix every 72 s) that
//! is a bit over 20 hours of one-way silence.
//!
//! # What each half of this file proves
//!
//! * `the_forward_distance_boundary_is_mdks_own_and_a_self_update_resets_it`
//!   is the MECHANISM, walked to the real boundary. It drives `OpenMLS` directly,
//!   at the configuration MDK installs — `cgka_engine::wire_format::join_config`
//!   is what MDK hands `StagedWelcome::new_from_welcome`
//!   (`group_lifecycle.rs:518-522`), so the receiver under test runs MDK's own
//!   `maximum_forward_distance`, read at runtime rather than hard-coded. That
//!   makes this test the detector the upstream ask needs
//!   (`docs/MDK_UPSTREAM_TRACKER.md` T-FORWARD-DISTANCE): the day MDK overrides
//!   the configuration, or `OpenMLS` changes its default, the observed boundary
//!   and this expectation part company and this goes red.
//! * `rotation_uses_a_real_self_update_and_advances_every_sender_ratchet` is the
//!   HAVEN path: the repair is a real self-update — the repairer's leaf changes
//!   — both members apply it, and the circle still sends and receives
//!   afterwards.
//!
//! # Why the mechanism half does not go through `CircleManager`
//!
//! It cannot. The engine's send path re-reads every retained message for the
//! group on **every** send (`should_queue_outbound_intent` →
//! `advance_convergence_inputs_until_settled` → `list_messages` over
//! `[tip - 5, …]`, and a Haven circle's tip does not move), so walking a
//! thousand sends is quadratic. Measured at MDK `e391adc` on a debug build:
//! sends 0–100 took 64 s and sends 100–200 a further 197 s, extrapolating to
//! ~1.8 hours for the full walk — and no MDK API can prune the rows that cause
//! it (`MessageStorage` has no delete). Driving `OpenMLS` at MDK's configuration
//! measures exactly the same ratchet under exactly the same numbers, in seconds.
//! (The quadratic itself is a real production cost, not a test artefact: a
//! circle publishing 50 fixes an hour into an epoch that never advances is
//! paying an O(rows) scan per publish. Recorded here rather than hidden.)
//!
//! The two halves meet at the wire-format policy, which is pinned below: MDK
//! runs `PURE_PLAINTEXT_WIRE_FORMAT_POLICY`, so commits travel as
//! `PublicMessage` and never touch the `SecretTree` — which is why a member whose
//! application ratchet is exhausted can still ingest and apply the commit that
//! repairs it. The mechanism half exercises that directly, on a commit built the
//! way MDK builds a self-update (`cgka-engine/src/self_update.rs` 145-160:
//! `force_self_update(true)`, `consume_proposal_store(false)`), asserted to
//! carry an `UpdatePath`: the repairer's leaf is rotated, and the new epoch's
//! secret restarts every sender ratchet.

use cgka_engine::wire_format::{join_config, PURE_PLAINTEXT_WIRE_FORMAT_POLICY};
use cgka_engine::{DEFAULT_CIPHERSUITE, DEFAULT_MAX_PAST_EPOCHS};
use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage, SkipReason};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId as HavenGroupId, LocationMessageResult};
use haven_core::relay::fanout::{EvolutionStatus, RepairOutcome};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::Keys;
use openmls::framing::errors::{MessageDecryptionError, SecretTreeError};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use tempfile::TempDir;
use tls_codec::{Deserialize as _, Serialize as _};

// ══ The mechanism, at MDK's own configuration ═══════════════════════════════

/// The largest forward distance this test is willing to walk one message at a
/// time.
///
/// Every message below is a real MLS encryption and a real `process_message`, so
/// the cost is linear in the configured distance (the current 1000 costs ~2 s).
/// If upstream raises the default towards the 100 000 the plan asks for
/// (`docs/EPOCH_ROTATION_REPAIR_PLAN.md` §6(b)), this test must be re-scoped
/// against an injectable configuration rather than silently becoming minutes of
/// CI time — and the whole C4 premise it exists to prove would need revisiting
/// anyway. So it fails loudly with that instruction instead.
const MAX_WALKABLE_FORWARD_DISTANCE: u32 = 16_384;

/// One MLS participant: its own provider (so its key material and its ratchet
/// state are genuinely separate) plus its signer and credential.
struct Party {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
}

impl Party {
    fn new(name: &str) -> Self {
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(DEFAULT_CIPHERSUITE.signature_algorithm())
            .expect("generate a signature key pair");
        signer
            .store(provider.storage())
            .expect("store the signature key pair");
        let credential = CredentialWithKey {
            credential: BasicCredential::new(name.as_bytes().to_vec()).into(),
            signature_key: signer.public().into(),
        };
        Self {
            provider,
            signer,
            credential,
        }
    }

    fn key_package(&self) -> KeyPackage {
        KeyPackage::builder()
            .leaf_node_capabilities(marmot_leaf_capabilities())
            .build(
                DEFAULT_CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .expect("build a key package")
            .key_package()
            .clone()
    }
}

/// The leaf capabilities MDK advertises, reduced to the extensions and the
/// proposal type a Marmot group carries.
///
/// Copied in spirit from `cgka-engine`'s `leaf_capabilities`.
fn marmot_leaf_capabilities() -> Capabilities {
    Capabilities::new(
        None,
        Some(&[DEFAULT_CIPHERSUITE]),
        Some(&[
            ExtensionType::RequiredCapabilities,
            ExtensionType::AppDataDictionary,
            ExtensionType::LastResort,
        ]),
        Some(&[ProposalType::AppDataUpdate]),
        None,
    )
}

/// Re-serializes an outbound MLS message and reads it back as the wire form a
/// peer would receive, so nothing under test is handed an in-memory shortcut.
fn over_the_wire(out: &MlsMessageOut) -> MlsMessageIn {
    let bytes = out.tls_serialize_detached().expect("serialize");
    MlsMessageIn::tls_deserialize_exact(bytes.as_slice()).expect("deserialize")
}

/// What a receiver got out of one message.
///
/// The refusal is classified HERE, where the concrete error type is inferred,
/// and it is matched on the typed variant — never on message text.
#[derive(Debug)]
enum Received {
    /// The plaintext the sender put in.
    Application(Vec<u8>),
    /// The sender ratchet refused: this generation is past its forward-distance
    /// ceiling. This is C4.
    TooDistantInTheFuture,
    /// Anything else. Always a test bug, never an expected outcome, so it
    /// carries the rendered error purely so a failure says what happened.
    OtherFailure(String),
}

fn receive(group: &mut MlsGroup, provider: &OpenMlsRustCrypto, out: &MlsMessageOut) -> Received {
    let protocol = over_the_wire(out)
        .try_into_protocol_message()
        .expect("an application message is a protocol message");
    match group.process_message(provider, protocol) {
        Ok(processed) => match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => {
                Received::Application(app.into_bytes())
            }
            _ => panic!("expected an application message, got a different content kind"),
        },
        Err(ProcessMessageError::ValidationError(ValidationError::UnableToDecrypt(
            MessageDecryptionError::SecretTreeError(SecretTreeError::TooDistantInTheFuture),
        ))) => Received::TooDistantInTheFuture,
        Err(other) => Received::OtherFailure(format!("{other:?}")),
    }
}

/// Builds the commit Haven's repair asks the engine for: a self-update, staged
/// the way `cgka-engine`'s `do_send_self_update` stages one
/// (`self_update.rs` 145-160) — this device's leaf rotated through an
/// `UpdatePath`, and no stored proposal taken in.
fn self_update_commit(group: &mut MlsGroup, party: &Party) -> MlsMessageOut {
    let bundle = group
        .commit_builder()
        .consume_proposal_store(false)
        .force_self_update(true)
        .load_psks(party.provider.storage())
        .expect("load psks")
        .build(
            party.provider.rand(),
            party.provider.crypto(),
            &party.signer,
            |_| true,
        )
        .expect("build the self-update")
        .stage_commit(&party.provider)
        .expect("stage the self-update");
    let (commit, _welcome, _group_info) = bundle.into_contents();
    commit
}

/// A three-member group at MDK's own configuration: `alice` creates it and adds
/// `bob` and `carol`, who join from the Welcome through the very
/// `join_config` MDK hands `StagedWelcome::new_from_welcome`.
fn three_member_group(
    mdk_join: &MlsGroupJoinConfig,
    alice: &Party,
    bob: &Party,
    carol: &Party,
) -> (MlsGroup, MlsGroup, MlsGroup) {
    let create_config = MlsGroupCreateConfig::builder()
        .ciphersuite(DEFAULT_CIPHERSUITE)
        .capabilities(marmot_leaf_capabilities())
        .wire_format_policy(PURE_PLAINTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(DEFAULT_MAX_PAST_EPOCHS)
        .use_ratchet_tree_extension(true)
        .build();
    let mut alice_group = MlsGroup::new(
        &alice.provider,
        &alice.signer,
        &create_config,
        alice.credential.clone(),
    )
    .expect("create the group");

    let (_commit, welcome, _gi) = alice_group
        .add_members(
            &alice.provider,
            &alice.signer,
            &[bob.key_package(), carol.key_package()],
        )
        .expect("add bob and carol");
    alice_group
        .merge_pending_commit(&alice.provider)
        .expect("alice merges the add");

    let MlsMessageBodyIn::Welcome(welcome_in) = over_the_wire(&welcome).extract() else {
        panic!("the add must produce a welcome");
    };
    let bob_group =
        StagedWelcome::new_from_welcome(&bob.provider, mdk_join, welcome_in.clone(), None)
            .expect("stage bob's welcome")
            .into_group(&bob.provider)
            .expect("bob joins");
    let carol_group = StagedWelcome::new_from_welcome(&carol.provider, mdk_join, welcome_in, None)
        .expect("stage carol's welcome")
        .into_group(&carol.provider)
        .expect("carol joins");
    (alice_group, bob_group, carol_group)
}

/// Processes a commit the way a peer receives it: over the wire, through
/// `process_message`, as a staged commit.
fn receive_commit(
    group: &mut MlsGroup,
    provider: &OpenMlsRustCrypto,
    commit: &MlsMessageOut,
) -> ProcessedMessage {
    let proto = over_the_wire(commit)
        .try_into_protocol_message()
        .expect("a commit is a protocol message");
    group
        .process_message(provider, proto)
        .expect("a member whose application ratchet is exhausted must still process a commit")
}

/// Publishes past the sender-ratchet ceiling while nobody receives, then pins
/// BOTH edges of the boundary and its permanence.
///
/// The inclusive edge is probed on `carol`, who is otherwise untouched: a
/// SUCCESSFUL decryption advances the receiver's head, so probing it on the
/// device under test would un-stick that device before the repair could be shown
/// to do anything. `bob` is left exactly where he started — at generation 0 —
/// because a failed decryption advances nothing.
fn walk_past_the_ceiling_and_pin_both_edges(
    alice: &Party,
    alice_group: &mut MlsGroup,
    (bob, bob_group): (&Party, &mut MlsGroup),
    (carol, carol_group): (&Party, &mut MlsGroup),
    max_forward_distance: u32,
) {
    let distance = usize::try_from(max_forward_distance).expect("a forward distance fits usize");

    // The field shape: the receivers' sockets are dead, and every kind-445
    // carries a 228 s NIP-40 expiration, so relays delete what was missed and
    // there is nothing to replay.
    let mut sent: Vec<MlsMessageOut> = Vec::with_capacity(distance + 3);
    for n in 0..=(max_forward_distance + 2) {
        sent.push(
            alice_group
                .create_message(&alice.provider, &alice.signer, &n.to_be_bytes())
                .unwrap_or_else(|e| panic!("alice's message #{n}: {e:?}")),
        );
    }

    // The INCLUSIVE edge: exactly `maximum_forward_distance` skipped generations
    // still decrypts.
    match receive(carol_group, &carol.provider, &sent[distance]) {
        Received::Application(payload) => assert_eq!(
            payload,
            max_forward_distance.to_be_bytes().to_vec(),
            "generation {distance} must decrypt to the message alice actually sent"
        ),
        Received::TooDistantInTheFuture => panic!(
            "generation {distance} is exactly the configured forward distance and must \
             decrypt, but the sender ratchet refused it"
        ),
        Received::OtherFailure(why) => panic!(
            "generation {distance} is exactly the configured forward distance and must \
             decrypt: {why}"
        ),
    }

    // The EXCLUSIVE edge, on the device under test.
    let refusal = receive(bob_group, &bob.provider, &sent[distance + 1]);
    assert!(
        matches!(refusal, Received::TooDistantInTheFuture),
        "generation {} is one past the configured forward distance and must be refused by \
         the sender ratchet, got {refusal:?}",
        distance + 1
    );

    // And it stays that way for everything Alice sends afterwards — this is what
    // makes C4 permanent rather than one lost message.
    let still = receive(bob_group, &bob.provider, &sent[distance + 2]);
    assert!(
        matches!(still, Received::TooDistantInTheFuture),
        "an exhausted ratchet must stay exhausted; nothing in the receive path rewinds it, \
         got {still:?}"
    );
}

#[test]
fn the_forward_distance_boundary_is_mdks_own_and_a_self_update_resets_it() {
    // MDK's OWN join configuration — the value it hands every joiner
    // (`group_lifecycle.rs`, `StagedWelcome::new_from_welcome(.., &join_config, ..)`),
    // read at runtime. Nothing here restates 1000.
    let mdk_join = join_config(DEFAULT_MAX_PAST_EPOCHS);
    assert_eq!(
        mdk_join.wire_format_policy(),
        PURE_PLAINTEXT_WIRE_FORMAT_POLICY,
        "the whole repair rests on commits riding PublicMessage; if MDK ever moved to a \
         ciphertext policy, an exhausted member could no longer apply the commit that \
         would repair it"
    );
    let max_forward_distance = mdk_join
        .sender_ratchet_configuration()
        .maximum_forward_distance();
    assert!(
        max_forward_distance <= MAX_WALKABLE_FORWARD_DISTANCE,
        "the configured sender-ratchet forward distance is now {max_forward_distance}, which \
         this test will not walk one message at a time. That is very likely the upstream fix \
         this test exists to detect (docs/EPOCH_ROTATION_REPAIR_PLAN.md §6): re-scope the test \
         against an injectable configuration rather than raising \
         MAX_WALKABLE_FORWARD_DISTANCE."
    );
    let alice = Party::new("alice");
    let bob = Party::new("bob");
    let carol = Party::new("carol");
    let (mut alice_group, mut bob_group, mut carol_group) =
        three_member_group(&mdk_join, &alice, &bob, &carol);

    walk_past_the_ceiling_and_pin_both_edges(
        &alice,
        &mut alice_group,
        (&bob, &mut bob_group),
        (&carol, &mut carol_group),
        max_forward_distance,
    );

    // ── The repair ───────────────────────────────────────────────────────────

    let leaf_before = alice_group
        .own_leaf_node()
        .expect("alice's leaf")
        .encryption_key()
        .clone();
    let commit = self_update_commit(&mut alice_group, &alice);
    alice_group
        .merge_pending_commit(&alice.provider)
        .expect("alice merges her own repair commit");
    assert_ne!(
        alice_group
            .own_leaf_node()
            .expect("alice's leaf")
            .encryption_key(),
        &leaf_before,
        "the repair rotates the repairer's leaf key"
    );

    // THE LOAD-BEARING INVARIANT: Bob ingests and applies the commit while his
    // application ratchet for Alice is exhausted. Commits ride `PublicMessage`
    // and never touch the SecretTree, so the ratchet that cannot decrypt Alice's
    // locations is irrelevant to the commit that repairs it.
    let processed = receive_commit(&mut bob_group, &bob.provider, &commit);
    let ProcessedMessageContent::StagedCommitMessage(staged) = processed.into_content() else {
        panic!("the repair must arrive as a commit");
    };
    // Documentation accuracy, enforced: this commit carries an `UpdatePath`,
    // so the repair is a real key rotation of the repairer's leaf.
    assert!(
        staged.update_path_leaf_node().is_some(),
        "the repair commit must carry an UpdatePath — it is a self-update"
    );
    bob_group
        .merge_staged_commit(&bob.provider, *staged)
        .expect("bob merges the repair commit");

    assert_eq!(
        bob_group.epoch(),
        alice_group.epoch(),
        "author and peer must land on the same epoch"
    );

    // The payoff: Alice's next message starts a fresh ratchet at generation 0,
    // and Bob hears her again.
    let after_repair = alice_group
        .create_message(&alice.provider, &alice.signer, b"audible again")
        .expect("alice sends after the repair");
    match receive(&mut bob_group, &bob.provider, &after_repair) {
        Received::Application(payload) => assert_eq!(payload, b"audible again".to_vec()),
        Received::TooDistantInTheFuture => panic!(
            "after the repair the peer must be audible again — the commit did not reset \
             the sender ratchet, which is the whole point of the unit"
        ),
        Received::OtherFailure(why) => {
            panic!("after the repair the peer must be audible again: {why}")
        }
    }
}

// ══ The Haven path ══════════════════════════════════════════════════════════

const GROUP_RELAY: &str = "wss://group.example.com";

/// A member with their own real MLS store, plus the `KeyPackage` that lets
/// someone invite them.
struct Member {
    manager: CircleManager,
    keys: Keys,
    _dir: TempDir,
    key_package: MemberKeyPackage,
}

async fn new_member() -> Member {
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
    let key_package = MemberKeyPackage {
        key_package_event,
        inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
        nip65_relays: vec![],
        nip65_write_relays: vec![],
    };
    Member {
        manager,
        keys,
        _dir: dir,
        key_package,
    }
}

/// A real two-member Haven circle, built through the public API: Alice founds
/// it, Bob joins.
async fn haven_two_member_circle() -> (CircleManager, Keys, Member, HavenGroupId) {
    let relays = vec![GROUP_RELAY.to_string()];
    let bob = new_member().await;
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

    let config = CircleConfig::new("Ratchet Repair Circle").with_relays(relays.clone());
    let created = alice
        .create_circle(&alice_keys, vec![bob.key_package.clone()], &config)
        .await
        .expect("create circle");
    let mls_group_id: HavenGroupId = created.circle.mls_group_id.clone();
    let welcome = &created.welcome_events[0];
    bob.manager
        .process_gift_wrapped_invitation(&bob.keys, &welcome.event)
        .await
        .expect("bob processes welcome");
    bob.manager
        .accept_invitation(&welcome.event.id)
        .await
        .expect("bob accepts");
    // The temp dir must outlive the manager, so it is leaked into the test's
    // lifetime rather than dropped here.
    std::mem::forget(alice_dir);
    (alice, alice_keys, bob, mls_group_id)
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn rotation_uses_a_real_self_update_and_advances_every_sender_ratchet() {
    let (alice, alice_keys, bob, mls_group_id) = haven_two_member_circle().await;

    let before = alice
        .session()
        .epoch(&mls_group_id)
        .await
        .expect("alice epoch");
    let leaf_before = alice
        .session()
        .own_leaf_hash_for_test(&mls_group_id)
        .await
        .expect("alice's leaf");

    // A clock past every rotation window. The gate matrix itself is covered
    // exhaustively by `circle::rotation`'s unit tests and by the manager tests;
    // what this asserts is that the commit the gates let through is a real
    // self-update that lands on the peer and leaves the circle working.
    let now = u64::try_from(chrono::Utc::now().timestamp()).expect("a positive unix clock")
        + 25 * 60 * 60;
    let (outcome, commit) = alice
        .repair_rotation_for_test(&mls_group_id, now)
        .await
        .expect("the repair must not fail for a member of a quiet circle");
    let (RepairOutcome::Rotated(made), Some(commit)) = (&outcome, commit) else {
        panic!("a member of a quiet circle must make a rotation, got {outcome:?}");
    };
    assert_eq!(
        made.status,
        EvolutionStatus::Confirmed,
        "the rotation is applied on a relay's ack"
    );
    assert_eq!(
        commit.kind.as_u16(),
        445,
        "the repair commit rides the ordinary group-message kind"
    );
    assert_ne!(
        alice
            .session()
            .own_leaf_hash_for_test(&mls_group_id)
            .await
            .expect("alice's leaf"),
        leaf_before,
        "the repair is a self-update: the repairer's leaf is rotated"
    );

    bob.manager
        .ingest_for_test(&commit)
        .await
        .expect("bob ingests the repair commit");

    for (who, mgr) in [("alice", &alice), ("bob", &bob.manager)] {
        assert_eq!(
            mgr.session()
                .epoch(&mls_group_id)
                .await
                .unwrap_or_else(|e| panic!("{who} epoch: {e}")),
            before + 1,
            "{who} must have applied the repair: a new epoch restarts every sender ratchet"
        );
    }

    // The self-update changes nobody's permissions.
    assert_eq!(
        bob.manager
            .session()
            .admin_pubkeys(&mls_group_id)
            .await
            .expect("bob admins"),
        vec![alice_keys.public_key().to_bytes()],
        "applying the repair must leave the peer's admin set exactly as it was"
    );

    // The circle still works in both directions afterwards.
    let (from_bob, _ngid, _relays) = bob
        .manager
        .seal_location_for_test(&mls_group_id, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("bob sends after the repair");
    let results = alice
        .ingest_for_test(&from_bob)
        .await
        .expect("alice ingests bob's location");
    assert!(
        results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::Location { .. })),
        "the repairer must hear the peer after the repair"
    );
    let (from_alice, _ngid, _relays) = alice
        .seal_location_for_test(&mls_group_id, &LocationMessage::new(48.86, 2.36))
        .await
        .expect("alice sends after the repair");
    let results = bob
        .manager
        .ingest_for_test(&from_alice)
        .await
        .expect("bob ingests alice's location");
    assert!(
        results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::Location { .. })),
        "the peer must hear the repairer after the repair"
    );

    // And the repair is rate-limited: the epoch it just moved is itself the
    // evidence gate 3 reads, so a second tap at the REAL clock (which is what
    // production passes) is declined.
    let real_now = u64::try_from(chrono::Utc::now().timestamp()).expect("a positive unix clock");
    assert!(
        matches!(
            alice
                .repair_rotation_for_test(&mls_group_id, real_now)
                .await
                .expect("outcome")
                .0,
            RepairOutcome::Skipped(SkipReason::RecentEpochChange | SkipReason::RotatedRecently)
        ),
        "a circle whose epoch has just moved must not be repaired again"
    );
}
