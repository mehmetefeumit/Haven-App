//! The `test-utils` seams the Tier-1 soak rig drives, each proved against the
//! real engine.
//!
//! A seam is a promise made to a harness in another crate, so it carries the
//! same obligation as a production promise: a test that fails when it breaks.
//! Every test here drives a genuine `AccountDeviceSession` over a genuine
//! `SQLCipher` database — none of them plants a row to "reach" the state it
//! asserts.
//!
//! Five are READ seams, and the sixth is not: `set_stored_message_write_fault_
//! for_test` MUTATES a live database so a harness can make a write the engine
//! performs mid-call fail. It is listed last and marked, because "a harness can
//! see state the product does not expose" is not a true description of it.
//!
//! The six seams and what each is for:
//!
//! 1. `SessionManager::process_event_typed_for_test` — one ingest of one event
//!    that keeps BOTH pre-authentication screens and hands back the engine's own
//!    error type, so a classifier can match a variant instead of parsing
//!    redacted prose.
//! 2. `SessionManager::stored_message_record_for_test` — a stored row's
//!    disposition AND epoch, which is what tells a branch loss from an ordinary
//!    past-epoch drop.
//! 3. `LiveSyncCore::processor` — the engine processor a quiescence predicate
//!    must read, rather than a second one built over the same state.
//! 4. `CircleManager::circle_rotation_state` — the rotation stamps a harness
//!    must compute gate expectations FROM, because the write side stamps real
//!    time and a stepped policy clock cannot be substituted for them.
//! 5. `openmls_group_keys_for_test` / `delete_openmls_group_state_for_test` —
//!    the only honest way to induce hydration quarantine, which the engine sets
//!    at session open and offers no API to trigger.
//! 6. `set_stored_message_write_fault_for_test` — the one WRITE seam, and the
//!    only deterministic way to make an in-flight engine call fail after it has
//!    already emitted: it installs a `BEFORE UPDATE` abort trigger on the
//!    engine's stored-message table, in a LIVE database, so a replay can be
//!    aborted between the event buffer and the durable row. Unlike the other
//!    five it changes what the engine does rather than revealing it, which is
//!    why it is armed and disarmed around one call and never left in place.
//!
//! # Rule 15 over this file
//!
//! `SessionError`, `EngineError` and `IngestEffects` are MATCHED here, never
//! formatted: `EngineError::ForkedEpoch`'s derived `Debug` prints a real MLS
//! group id and its `Display` prints two absolute epochs. There is no `{:?}` of
//! any `haven_core` / `cgka_*` / `nostr` / `openmls` value anywhere below, no
//! `.expect()` on a `Result<_, SessionError>`, and no assertion message that
//! interpolates an identifier or an instant.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{
    delete_openmls_group_state_for_test, openmls_group_keys_for_test,
    set_stored_message_write_fault_for_test, OpenMlsGroupKey,
};
use haven_core::nostr::mls::types::{
    EpochId, GroupId, IngestOutcome, LocationMessageResult, MessageId, MessageState,
    OpenMlsContentKind, PreAuthRejection, ScreenedIngest, StaleReason, StoredMessageProbe,
};
use haven_core::nostr::mls::StorageConfig;
use haven_core::relay::live_sync::{group_cursor_stream, LiveSyncCore};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Alphabet, Event, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind, Timestamp};
use tempfile::TempDir;

mod helpers;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log, haven_core_lines};

const GROUP_RELAY: &str = "wss://seams.example.com";

// ── Fixture ──────────────────────────────────────────────────────────────────

/// A device with its own real `SQLCipher` MLS store.
struct Device {
    manager: Arc<CircleManager>,
    keys: Keys,
    dir: TempDir,
}

impl Device {
    fn new() -> Self {
        let dir = TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let manager =
            Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("open a session"));
        Self { manager, keys, dir }
    }

    /// The device's own data directory, for a seam that opens a second handle.
    fn dir_path(&self) -> &std::path::Path {
        self.dir.path()
    }

    async fn key_package(&self) -> MemberKeyPackage {
        let key_package_event = build_kp_maintenance_events(
            self.manager.session(),
            &self.keys,
            &[GROUP_RELAY.to_string()],
            None,
            None,
        )
        .await
        .expect("mint a key package")
        .event;
        MemberKeyPackage {
            key_package_event,
            inbox_relays: vec![GROUP_RELAY.to_string()],
            nip65_relays: vec![],
        }
    }
}

/// A genuine two-member circle built through the public API: create → confirm →
/// welcome → accept. Every row under test is one production really wrote.
struct Circle {
    alice: Device,
    bob: Device,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
}

async fn two_member_circle(name: &str) -> Circle {
    let relays = vec![GROUP_RELAY.to_string()];
    let alice = Device::new();
    let bob = Device::new();

    let result = alice
        .manager
        .create_circle(
            &alice.keys,
            vec![bob.key_package().await],
            &CircleConfig::new(name).with_relays(relays.clone()),
            &relays,
        )
        .await
        .expect("create a circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .manager
        .confirm_published(result.pending)
        .await
        .expect("confirm the create");
    bob.manager
        .process_gift_wrapped_invitation(&bob.keys, &result.welcome_events[0].event)
        .await
        .expect("bob peels the welcome");
    bob.manager
        .accept_invitation(&result.welcome_events[0].event.id)
        .await
        .expect("bob joins");

    Circle {
        alice,
        bob,
        mls_group_id,
        nostr_group_id,
    }
}

/// Promotes Bob to admin so both devices may commit, leaving both on one epoch.
async fn make_co_admins(c: &Circle) {
    let handoff = c
        .alice
        .manager
        .propose_admin_handoff(&c.mls_group_id, &c.bob.keys.public_key())
        .await
        .expect("alice hands bob the admin bit");
    c.alice
        .manager
        .confirm_published(handoff.pending)
        .await
        .expect("confirm the handoff");
    c.bob
        .manager
        .decrypt_location(&handoff.commit_event)
        .await
        .expect("bob applies the handoff commit");
    assert!(
        c.alice.manager.group_epoch(&c.mls_group_id).await.unwrap()
            == c.bob.manager.group_epoch(&c.mls_group_id).await.unwrap(),
        "both devices must sit on one epoch before a same-epoch race means anything"
    );
}

/// A relay-list commit staged and confirmed by `dev`, returning the commit event
/// every co-member must apply.
async fn commit_relay_update(dev: &Device, group_id: &GroupId, relay: &str) -> Event {
    let staged = dev
        .manager
        .update_circle_relays(group_id, &[GROUP_RELAY.to_string(), relay.to_string()])
        .await
        .expect("stage a relay-list commit");
    dev.manager
        .finalize_relay_update(staged.pending, group_id)
        .await
        .expect("confirm the relay-list commit");
    staged.commit_event
}

/// The value-free shape of one ingest, so a test can assert which arm the engine
/// took without ever formatting an engine value.
#[derive(PartialEq, Eq, Debug)]
enum Arm {
    Applied,
    PastEpoch,
    Other,
}

/// Ingests `event` through the typed seam ONCE and reports which arm it took.
///
/// One event, one ingest, one call: the engine answers a second ingest of the
/// same MLS content with `Stale { AlreadySeen }`, so a helper that ingested
/// twice would classify the second look and turn a branch loss into a duplicate.
async fn ingest_arm(dev: &Device, event: &Event) -> Arm {
    let Ok(screened) = dev
        .manager
        .session()
        .process_event_typed_for_test(event)
        .await
    else {
        panic!("a co-member commit must not fail the ingest outright");
    };
    let ScreenedIngest::Ingested(effects) = screened else {
        panic!("a co-member commit passes both pre-auth screens");
    };
    match effects.outcome {
        IngestOutcome::Processed => Arm::Applied,
        IngestOutcome::Stale {
            reason: StaleReason::AlreadyAtEpoch { .. },
        } => Arm::PastEpoch,
        _ => Arm::Other,
    }
}

// ── Seam 1: the typed ingest keeps both pre-authentication screens ───────────

#[tokio::test]
async fn typed_ingest_keeps_the_expiration_screen() {
    let c = two_member_circle("typed expiry").await;
    let stale = EventBuilder::new(Kind::Custom(445), "never read: the screen runs first")
        .tags([
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                [hex::encode(c.nostr_group_id)],
            ),
            Tag::expiration(Timestamp::from(1)),
        ])
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    let Ok(screened) = c
        .bob
        .manager
        .session()
        .process_event_typed_for_test(&stale)
        .await
    else {
        panic!("an expired event is screened, never an engine failure");
    };
    assert!(
        matches!(
            screened,
            ScreenedIngest::RejectedBeforeAuth(PreAuthRejection::Expired)
        ),
        "the typed seam must run production's NIP-40 receiver screen, not skip it"
    );
}

#[tokio::test]
async fn typed_ingest_keeps_the_malformed_screen() {
    let c = two_member_circle("typed malformed").await;
    // No `h` tag at all: the pure pre-engine parse rejects it, and that is a
    // pre-authentication judgement, never an un-applied message.
    let unroutable = EventBuilder::new(Kind::Custom(445), "no routing tag")
        .sign_with_keys(&Keys::generate())
        .expect("sign");

    let Ok(screened) = c
        .bob
        .manager
        .session()
        .process_event_typed_for_test(&unroutable)
        .await
    else {
        panic!("an unparseable envelope is screened, never an engine failure");
    };
    assert!(
        matches!(
            screened,
            ScreenedIngest::RejectedBeforeAuth(PreAuthRejection::Malformed)
        ),
        "the typed seam must run production's pre-engine transport parse"
    );
}

#[tokio::test]
async fn typed_ingest_applies_a_real_group_event() {
    let c = two_member_circle("typed apply").await;
    let sent = c
        .alice
        .manager
        .encrypt_location(
            &c.mls_group_id,
            &c.alice.keys.public_key(),
            &LocationMessage::new(48.85, 2.35),
            60,
        )
        .await
        .expect("alice encrypts")
        .0;

    let Ok(screened) = c
        .bob
        .manager
        .session()
        .process_event_typed_for_test(&sent)
        .await
    else {
        panic!("a genuine co-member location must ingest");
    };
    let ScreenedIngest::Ingested(effects) = screened else {
        panic!("a screened-clean event must reach the engine");
    };
    assert!(
        matches!(effects.outcome, IngestOutcome::Processed),
        "the seam is production's body with one substitution, so it must APPLY \
         what production applies"
    );
}

// ── Seam 1: a genuine same-epoch commit race ────────────────────────────────

/// The engine's fork resolution, walked through the typed seam with two REAL
/// commits — never a planted row.
///
/// Both co-admins commit from one epoch and each ingests the other's. The
/// ordering key is content-derived and the comparison symmetric, so the same
/// commit wins on both devices: one side applies the peer's branch and the other
/// reports the peer's commit as past-epoch. WHICH side that is varies with the
/// commits' own fresh randomness, so "exactly one of each" is the invariant —
/// naming a winner would be a coin flip dressed up as an assertion.
#[tokio::test]
async fn a_same_epoch_race_costs_exactly_one_branch() {
    let c = two_member_circle("race").await;
    make_co_admins(&c).await;
    let alice_commit =
        commit_relay_update(&c.alice, &c.mls_group_id, "wss://alice.example.com").await;
    let bob_commit = commit_relay_update(&c.bob, &c.mls_group_id, "wss://bob.example.com").await;

    let arms = [
        ingest_arm(&c.alice, &bob_commit).await,
        ingest_arm(&c.bob, &alice_commit).await,
    ];
    assert_eq!(
        arms.iter().filter(|a| **a == Arm::PastEpoch).count(),
        1,
        "a same-epoch race must cost exactly one branch"
    );
    assert_eq!(
        arms.iter().filter(|a| **a == Arm::Applied).count(),
        1,
        "and the other device must APPLY the surviving branch, not drop it too"
    );

    // Convergence is the point of the resolution, so it is asserted as
    // behaviour: one epoch, and a location that really crosses.
    assert!(
        c.alice.manager.group_epoch(&c.mls_group_id).await.unwrap()
            == c.bob.manager.group_epoch(&c.mls_group_id).await.unwrap(),
        "both devices must land on one epoch after the race resolves"
    );
    let sent = c
        .alice
        .manager
        .encrypt_location(
            &c.mls_group_id,
            &c.alice.keys.public_key(),
            &LocationMessage::new(51.5, -0.12),
            60,
        )
        .await
        .expect("alice sends after the race")
        .0;
    assert!(
        c.bob
            .manager
            .decrypt_location(&sent)
            .await
            .expect("bob ingests")
            .iter()
            .any(|r| matches!(r, LocationMessageResult::Location { .. })),
        "equal epoch NUMBERS are not convergence; a decrypt is"
    );
}

// ── Seam 2: the stored probe ────────────────────────────────────────────────

/// The probe is what tells a branch loss from every other disposition, proved on
/// the loser of a REAL same-epoch commit race — never on a planted row.
///
/// # Why the row is located rather than addressed by the event id
///
/// The engine keys every stored row on a CONTENT-derived id — `SHA-256` over the
/// peeled MLS bytes (`content_dedup_id`, `cgka-engine/src/message_processor/mod.rs`)
/// — and deliberately NOT on the transport event id, so that one MLS message
/// re-wrapped in a fresh kind-445 envelope collapses to a single duplicate. A
/// caller holding only the signed event therefore CANNOT name the row its own
/// ingest just wrote; it locates it through `stored_convergence_input_for_test`,
/// or it knows the id because it staged the row itself. That constraint is
/// recorded here because a classifier that guessed the id would quietly probe
/// the wrong row and report a fork that never happened.
#[tokio::test]
async fn the_probe_reports_the_branch_the_engine_discarded() {
    let c = two_member_circle("probe").await;
    make_co_admins(&c).await;
    let alice_commit =
        commit_relay_update(&c.alice, &c.mls_group_id, "wss://alice-probe.example.com").await;
    let bob_commit =
        commit_relay_update(&c.bob, &c.mls_group_id, "wss://bob-probe.example.com").await;

    let arms = [
        ingest_arm(&c.alice, &bob_commit).await,
        ingest_arm(&c.bob, &alice_commit).await,
    ];
    let mut losses = 0;
    for (device, arm) in [(&c.alice, &arms[0]), (&c.bob, &arms[1])] {
        let probe = locate_commit_probe(device, &c.mls_group_id).await;
        let tip = device.manager.group_epoch(&c.mls_group_id).await.unwrap();
        if *arm == Arm::PastEpoch {
            losses += 1;
            assert_eq!(
                probe.state,
                MessageState::EpochInvalidated,
                "the device that reported the peer's commit past-epoch lost that \
                 branch, and `EpochInvalidated` is the ONLY signal saying so — the \
                 engine outcome alone cannot distinguish it from an ordinary \
                 past-epoch drop"
            );
            assert!(
                probe.epoch == EpochId(tip),
                "and the row carries its own epoch column — this device's tip when \
                 the engine stored it"
            );
        } else {
            assert_ne!(
                probe.state,
                MessageState::EpochInvalidated,
                "the device that APPLIED the surviving branch lost nothing"
            );
        }
    }
    assert_eq!(losses, 1, "a same-epoch race costs exactly one branch");

    assert!(
        c.alice
            .manager
            .session()
            .stored_message_record_for_test(&MessageId::new(vec![0u8; 32]))
            .await
            .expect("read a missing row")
            .is_none(),
        "an id no row uses must read as absent, never as a default disposition"
    );
}

/// The most recently stored commit row of `group_id` on this device, probed.
async fn locate_commit_probe(dev: &Device, group_id: &GroupId) -> StoredMessageProbe {
    let session = dev.manager.session();
    let record = session
        .stored_convergence_input_for_test(group_id, OpenMlsContentKind::Commit, 1)
        .await
        .expect("this device holds a real commit row");
    session
        .stored_message_record_for_test(&record.id)
        .await
        .expect("read the row")
        .expect("the row the locator just returned exists")
}

// ── Rule 15: forcing the fork path leaks no identifier ──────────────────────

/// The whole fork scenario is run inside a log capture with every identifier it
/// holds planted as a needle, and no line this crate wrote carries any of them.
///
/// The needles are the values the engine holds while the fork resolves: the real
/// MLS group id, the public `nostr_group_id`, both members' pubkeys, both
/// commits' event ids and the circle name. `EngineError::ForkedEpoch`'s derived
/// `Debug` prints the first of those and its `Display` prints two absolute
/// epochs — which is why this file matches those types and never formats them,
/// and why the engine's own error prose must reach no line either.
///
/// # The third-party residual, named rather than hidden
///
/// `openmls` logs the ENTIRE MLS group context as hex on
/// `openmls::ciphersuite::kdf_label` at debug level — group id, group name and
/// relay URLs included. No change inside `haven-core` can silence it; the only
/// lever is the log filter installed in `rust_builder::api::init_app` (the
/// release log silencer). So the needle assertion narrows to this crate's own
/// lines, and the root-target assertion below bounds the residual: a NEW
/// dependency logging on the MLS fork path reddens this test and gets reviewed
/// rather than inherited.
#[tokio::test]
async fn fork_classification_leaks_no_identifier() {
    const CIRCLE_NAME: &str = "fork needle circle";
    let facts: Mutex<Option<(Vec<String>, usize)>> = Mutex::new(None);

    let lines = capture_haven_log(async {
        let c = two_member_circle(CIRCLE_NAME).await;
        make_co_admins(&c).await;
        let alice_commit =
            commit_relay_update(&c.alice, &c.mls_group_id, "wss://alice-fork.example.com").await;
        let bob_commit =
            commit_relay_update(&c.bob, &c.mls_group_id, "wss://bob-fork.example.com").await;
        let arms = [
            ingest_arm(&c.alice, &bob_commit).await,
            ingest_arm(&c.bob, &alice_commit).await,
        ];
        *facts.lock().unwrap() = Some((
            vec![
                hex::encode(c.mls_group_id.as_slice()),
                hex::encode(c.nostr_group_id),
                c.alice.keys.public_key().to_hex(),
                c.bob.keys.public_key().to_hex(),
                alice_commit.id.to_hex(),
                bob_commit.id.to_hex(),
                CIRCLE_NAME.to_string(),
            ],
            arms.iter().filter(|a| **a == Arm::PastEpoch).count(),
        ));
    })
    .await;

    let (needles, branch_losses) = facts.into_inner().unwrap().expect("the scenario ran");
    assert_eq!(
        branch_losses, 1,
        "the capture must span a real branch loss, or its absences prove nothing"
    );

    let ours = haven_core_lines(&lines);
    assert_some_line_from(&lines, "haven_core");
    let borrowed: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_no_needles(&ours, &borrowed);

    let roots: BTreeSet<&str> = lines
        .iter()
        .filter_map(|l| l.target.split("::").next())
        .filter(|root| *root != "haven_core")
        .collect();
    assert_eq!(
        roots,
        BTreeSet::from(["openmls"]),
        "openmls is the one known third-party logger on this path and the release \
         log silencer is its only lever; a new one must be reviewed, not inherited"
    );

    // The absolute-epoch half. An epoch is a small decimal, so it cannot be a
    // needle without matching arbitrary prose; what CAN be asserted is that the
    // one thing on this path carrying one — the engine's own fork error text,
    // whose format is "forked epoch: last stable {…}, conflicting {…}" — reached
    // no line at all.
    for line in &lines {
        let text = line.message.to_lowercase();
        assert!(
            !text.contains("forked epoch")
                && !text.contains("last stable")
                && !text.contains("conflicting "),
            "the engine's fork error prose reached a log line from {}, and it \
             carries two absolute epochs (Security Rule 15)",
            line.target
        );
    }
}

// ── Seam 3: the processor accessor reaches the core's own engine ─────────────

#[tokio::test]
async fn the_processor_accessor_reaches_the_cores_own_processor() {
    let c = two_member_circle("processor").await;
    let group_hex = hex::encode(c.nostr_group_id);
    let stream = group_cursor_stream(&group_hex);
    let core = LiveSyncCore::new_local(Arc::clone(&c.alice.manager), c.alice.keys.public_key());

    assert!(
        core.processor().all_advances_consumed(),
        "a core with no open generation owes no advance"
    );
    core.processor()
        .note_subscription_opened(&group_hex, 1_700_000_000);
    assert!(
        !core.processor().all_advances_consumed(),
        "an open generation owes an advance — read back THROUGH the accessor, so a \
         fresh processor per call would have answered otherwise"
    );
    assert!(
        core.processor().note_end_of_stored_events(&group_hex),
        "the first EOSE of a generation issues its advance"
    );
    assert!(
        !core.processor().note_end_of_stored_events(&group_hex),
        "and the same generation advances exactly once"
    );
    assert!(
        c.alice
            .manager
            .read_sync_cursor(&stream)
            .expect("read the cursor")
            .is_some(),
        "the advance must land in the SAME CircleManager the core was built over"
    );
}

// ── Seam 4: the rotation stamps come back from the write side ───────────────

#[tokio::test]
async fn circle_rotation_state_reads_back_what_the_write_side_stamped() {
    let c = two_member_circle("rotation stamps").await;
    let before = c
        .bob
        .manager
        .circle_rotation_state(&c.nostr_group_id)
        .expect("read the stamps");
    assert!(
        before.last_epoch_change_seen_at_ms.is_none()
            && before.last_inbound_event_at_ms.is_none()
            && before.last_rotation_at_ms.is_none(),
        "a circle that has seen no inbound group event carries no evidence, and a \
         gate must read that as 'no evidence' rather than as 'just now'"
    );

    let floor_ms = chrono::Utc::now().timestamp_millis();
    let commit = commit_relay_update(&c.alice, &c.mls_group_id, "wss://rotation.example.com").await;
    c.bob
        .manager
        .decrypt_location(&commit)
        .await
        .expect("bob applies the commit");
    let ceiling_ms = chrono::Utc::now().timestamp_millis();

    let after = c
        .bob
        .manager
        .circle_rotation_state(&c.nostr_group_id)
        .expect("read the stamps");
    for stamp in [
        after.last_epoch_change_seen_at_ms,
        after.last_inbound_event_at_ms,
    ] {
        let at = stamp.expect("an applied commit stamps both instants");
        assert!(
            (floor_ms..=ceiling_ms).contains(&at),
            "the stamp must be the REAL instant the write side recorded, which is \
             exactly why a harness may never compute a gate expectation from its \
             own clock offset"
        );
    }
    assert!(
        after.last_rotation_at_ms.is_none(),
        "only a confirmed REPAIR rotation spends the rate limit; applying a peer's \
         commit must not"
    );
}

// ── Seam 5: inducing hydration quarantine ───────────────────────────────────

/// The engine sets hydration quarantine only at session open and exposes no way
/// to trigger it, so the only honest induction is to remove the `OpenMLS` state
/// one group hydrates from — on a CLOSED database — and reopen.
#[tokio::test]
async fn deleting_one_groups_openmls_state_quarantines_exactly_that_group() {
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let relays = vec![GROUP_RELAY.to_string()];
    let db = StorageConfig::new(dir.path()).database_path();
    let key = StorageConfig::test_sqlcipher_key().expect("the test key");

    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("open a session");
    let healthy = create_confirmed_circle(&manager, &keys, "healthy", &relays).await;
    // Rule 14: only a CLOSED database may be opened by a second handle.
    drop(manager);
    let before = openmls_group_keys_for_test(&db, &key).expect("read the openmls group keys");

    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("reopen");
    let victim = create_confirmed_circle(&manager, &keys, "victim", &relays).await;
    drop(manager);
    let after = openmls_group_keys_for_test(&db, &key).expect("read the openmls group keys");

    // Key discovery by set difference: `openmls_values.group_key` is an opaque
    // serde encoding, so the victim is identified as the single key the second
    // circle added — never by decoding one.
    let added: Vec<OpenMlsGroupKey> = after
        .iter()
        .filter(|k| !before.contains(k))
        .cloned()
        .collect();
    assert_eq!(
        added.len(),
        1,
        "creating one circle must add exactly one OpenMLS group key; anything else \
         means the pinned engine's schema or key encoding moved and this injection \
         needs re-aiming — NOT that the invariant under test changed"
    );

    let removed = delete_openmls_group_state_for_test(&db, &key, &added[0])
        .expect("delete the victim's OpenMLS state");
    assert!(
        removed > 0,
        "a group key matching no row would make the reopen below vacuous"
    );

    let reopened = CircleManager::new_unencrypted(dir.path(), &keys)
        .expect("the session reopens with one group unhydratable");
    let quarantined = reopened.session().quarantined_group_ids().await;
    assert!(
        quarantined.contains(&victim),
        "a group whose OpenMLS state will not load must be quarantined at open"
    );
    assert!(
        !quarantined.contains(&healthy),
        "and a sibling group in the SAME database must not be"
    );
    reopened
        .encrypt_location(
            &healthy,
            &keys.public_key(),
            &LocationMessage::new(51.5, -0.12),
            60,
        )
        .await
        .expect("the healthy sibling must still send after the reopen");
}

/// Creates and confirms a one-invitee circle, returning its MLS group id.
async fn create_confirmed_circle(
    manager: &CircleManager,
    keys: &Keys,
    name: &str,
    relays: &[String],
) -> GroupId {
    let invitee = Device::new();
    let result = manager
        .create_circle(
            keys,
            vec![invitee.key_package().await],
            &CircleConfig::new(name).with_relays(relays.to_vec()),
            relays,
        )
        .await
        .expect("create a circle");
    manager
        .confirm_published(result.pending)
        .await
        .expect("confirm the create");
    result.circle.mls_group_id
}

// ── Seam 6: the write fault ─────────────────────────────────────────────────

/// The one MUTATION seam: arming it makes the engine's own stored-message write
/// fail, and disarming it restores the call it broke.
///
/// This is the only way to reach the shape that matters for Rule 12 — an engine
/// call that has ALREADY handed a decrypted peer message to the application and
/// then fails before its durable row is written. Both directions are asserted,
/// because a fault that could not be lifted would make every later test in the
/// same database a fiction, and a fault that never bit would make the tests it
/// exists for vacuous.
#[tokio::test]
async fn the_write_fault_breaks_exactly_one_engine_write_and_then_lets_go() {
    let c = two_member_circle("write fault").await;
    // ALICE's database, because the seam is only useful against a LIVE session:
    // the write it breaks is one the engine makes in the middle of a call.
    let db = StorageConfig::new(c.alice.dir_path()).database_path();
    let key = StorageConfig::test_sqlcipher_key().expect("the test key");

    let first = c
        .bob
        .manager
        .encrypt_location(
            &c.mls_group_id,
            &c.bob.keys.public_key(),
            &LocationMessage::new(51.5, -0.12),
            60,
        )
        .await
        .expect("bob sends");

    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm the fault");
    assert!(
        c.alice
            .manager
            .session()
            .process_event(&first.0)
            .await
            .is_err(),
        "armed, the engine's own stored-message write must fail the ingest — the \
         seam is useless if the call it is aimed at still succeeds"
    );
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm the fault");

    let second = c
        .bob
        .manager
        .encrypt_location(
            &c.mls_group_id,
            &c.bob.keys.public_key(),
            &LocationMessage::new(48.85, 2.35),
            60,
        )
        .await
        .expect("bob sends again");
    assert!(
        c.alice
            .manager
            .session()
            .process_event(&second.0)
            .await
            .is_ok(),
        "disarmed, the same call must succeed again: a fault that outlived its \
         own scope would make every later assertion in this database a fiction"
    );
}

/// The seam does not exist without the feature that gates it.
///
/// Structural rather than behavioural, because a test cannot compile against a
/// symbol that is not there: what is asserted is that the declaration carries
/// the gate, in the same file the shipped build compiles.
#[test]
fn the_write_fault_is_gated_by_the_test_utils_feature() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/storage.rs"),
    )
    .expect("read the storage module");
    let declaration = source
        .find("pub fn set_stored_message_write_fault_for_test")
        .expect("the seam is declared here");
    let gate = source[..declaration]
        .rfind("#[cfg(any(test, feature = \"test-utils\"))]")
        .expect("and it carries a gate");
    assert!(
        !source[gate..declaration].contains("pub fn "),
        "the gate must be the seam's OWN attribute, not one belonging to an \
         earlier item — a mutation seam in a shipped build is a lever on the \
         user's MLS store"
    );
}

/// A database the engine never wrote is refused, loudly, instead of reporting an
/// empty key set — which a caller would read as "this circle added no group" and
/// then quietly delete nothing.
#[tokio::test]
async fn the_injection_seam_refuses_a_database_the_engine_never_wrote() {
    let key = StorageConfig::test_sqlcipher_key().expect("the test key");

    // A real key, so the refusals below are about the DATABASE rather than about
    // a handle this test invented — which it could not: the type is opaque and
    // has no constructor outside its module.
    let real = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(real.path(), &keys).expect("open a session");
    create_confirmed_circle(&manager, &keys, "refusal", &[GROUP_RELAY.to_string()]).await;
    drop(manager);
    let group = openmls_group_keys_for_test(&StorageConfig::new(real.path()).database_path(), &key)
        .expect("a real store answers")
        .into_iter()
        .next()
        .expect("a confirmed circle has OpenMLS state");

    let empty = TempDir::new().expect("temp dir");
    let no_schema = empty.path().join("session.sqlite");
    assert!(
        openmls_group_keys_for_test(&no_schema, &key).is_err(),
        "a store with no engine schema must be an error, never an empty answer"
    );
    assert!(
        delete_openmls_group_state_for_test(&no_schema, &key, &group).is_err(),
        "and a delete against it must not report success"
    );
}
