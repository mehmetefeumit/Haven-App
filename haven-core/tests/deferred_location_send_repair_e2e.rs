//! One stuck inbound row must not silently kill a circle's OUTBOUND sends.
//!
//! `cgka-engine`'s `do_send` does not encrypt while
//! `should_queue_outbound_intent` holds: it persists a `QueuedOutboundIntent`
//! and returns `SendResult::Queued`. That predicate is true for exactly two
//! reasons; these tests cover the first.
//!
//! # 1. A stored row the convergence gate cannot settle
//!
//! `has_unresolved_convergence_inputs` looks at stored messages inside
//! `[epoch - max_rewind, epoch + max_rewind]` that are `Created` or `Retryable`.
//! A Haven circle's epoch only advances on a membership change, so for a stable
//! circle that window is its entire life.
//!
//! At MDK v0.10.4 a commit there always gates, but an APPLICATION row gates
//! only while retained competing commit edges make it a branch witness
//! (`ConvergenceInputContext::gates_outbound`): unresolved delivery alone no
//! longer makes group state ambiguous. So the shape these tests were written
//! for at `e391adc` — one undecryptable location row silently stopping every
//! send for the circle — no longer happens, and the tests pin that it does not:
//!
//! - a **current-epoch** application row no longer gates, and the engine leaves
//!   its disposition alone;
//! - a **future-epoch** application row (`tip < source_epoch <= tip + max_rewind`)
//!   no longer gates either, and it is still kept `Retryable` across a session
//!   open, so the commit that would make it decryptable can still arrive.
//!
//! Haven's age-based sweep still retires an application row the relay can no
//! longer redeliver, at runtime and at every session open: the row would
//! otherwise sit in the store for the circle's life, and it gates again the
//! moment a competing commit makes it a witness.
//!
//!
//! The second reason — a staged `SelfRemove` eviction in the send's own
//! preflight — is the fanout driver's: the staging hold records it, and
//! `poll_send_drive_e2e` pins that.

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{
    GroupId, LocationMessageResult, MessageRecord, MessageState, OpenMlsContentKind,
    UNRESOLVABLE_INPUT_MAX_AGE_SECS,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::Keys;
use tempfile::TempDir;

const GROUP_RELAY: &str = "wss://group.example.com";

/// A member with their own real `SQLCipher` MLS store, plus the `KeyPackage`
/// that lets someone invite them.
struct Member {
    manager: CircleManager,
    keys: Keys,
    dir: TempDir,
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
    };
    Member {
        manager,
        keys,
        dir,
        key_package,
    }
}

/// A genuine two-member circle (Alice admin + Bob co-member), built through the
/// PUBLIC circle API (create → confirm → welcome → accept), so every MLS row
/// under test is one the production path actually wrote.
struct TwoMemberCircle {
    alice: CircleManager,
    bob: CircleManager,
    bob_keys: Keys,
    bob_dir: TempDir,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _alice_dir: TempDir,
}

async fn build_two_member_circle() -> TwoMemberCircle {
    let relays = vec![GROUP_RELAY.to_string()];
    let bob = new_member().await;
    let alice_dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

    let config = CircleConfig::new("Deferred Send Repair Circle").with_relays(relays.clone());
    let result = alice
        .create_circle(&alice_keys, vec![bob.key_package], &config)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;

    let welcome = &result.welcome_events[0];
    bob.manager
        .process_gift_wrapped_invitation(&bob.keys, &welcome.event)
        .await
        .expect("bob processes welcome");
    bob.manager
        .accept_invitation(&welcome.event.id)
        .await
        .expect("bob accepts");

    TwoMemberCircle {
        alice,
        bob: bob.manager,
        bob_keys: bob.keys,
        bob_dir: bob.dir,
        mls_group_id,
        nostr_group_id,
        _alice_dir: alice_dir,
    }
}

/// Sends one location from `from` and asserts `to` decrypts it.
async fn send_and_receive(
    from: &CircleManager,
    to: &CircleManager,
    group_id: &GroupId,
    lat: f64,
    lon: f64,
) -> (nostr::Event, [u8; 32], Vec<String>) {
    let sent = from
        .seal_location_for_test(group_id, &LocationMessage::new(lat, lon))
        .await
        .expect("the sender must encrypt rather than queue");
    let results = to
        .ingest_for_test(&sent.0)
        .await
        .expect("the peer must ingest the location");
    assert!(
        results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::Location { .. })),
        "the peer must decrypt the location, not merely accept the envelope"
    );
    sent
}

/// Asserts a recovered send is a real routed kind-445, not merely a value the
/// call returned.
fn assert_well_formed_445(sent: &(nostr::Event, [u8; 32], Vec<String>), nostr_group_id: [u8; 32]) {
    let (event, ngid, relays) = sent;
    assert_eq!(event.kind.as_u16(), 445, "the group-message kind");
    assert_eq!(*ngid, nostr_group_id, "routed to this circle");
    assert_eq!(relays, &vec![GROUP_RELAY.to_string()]);
    let h_tag = event
        .tags
        .iter()
        .find_map(|t| {
            let slice = t.as_slice();
            (slice.first().map(String::as_str) == Some("h")).then(|| slice[1].clone())
        })
        .expect("a kind-445 carries the public nostr_group_id in #h");
    assert_eq!(h_tag, hex::encode(nostr_group_id));
    assert!(
        event
            .tags
            .iter()
            .any(|t| t.as_slice().first().map(String::as_str) == Some("expiration")),
        "the engine must still stamp the group's NIP-40 retention on the recovered send"
    );
}

/// Moves Alice one epoch ahead of Bob and returns a REAL application row she
/// sealed at that higher epoch — the future-epoch input the engine deliberately
/// never resolves.
///
/// The row is Alice's own stored `OpenMlsWire` record, taken verbatim: real MLS
/// wire bytes at a real epoch above Bob's tip, with the id production writes.
async fn alice_row_one_epoch_ahead(c: &TwoMemberCircle) -> MessageRecord {
    let carol = new_member().await;
    c.alice
        .add_members_for_test(&c.mls_group_id, &[carol.key_package])
        .await
        .expect("alice adds carol");
    let ahead = c
        .alice
        .session()
        .epoch(&c.mls_group_id)
        .await
        .expect("alice's epoch");
    assert_eq!(
        ahead,
        c.bob
            .session()
            .epoch(&c.mls_group_id)
            .await
            .expect("bob's epoch")
            + 1,
        "the fixture requires alice exactly one epoch ahead of bob"
    );
    c.alice
        .seal_location_for_test(&c.mls_group_id, &LocationMessage::new(5.0, 6.0))
        .await
        .expect("alice sends at the higher epoch");
    c.alice
        .session()
        .stored_convergence_input_for_test(&c.mls_group_id, OpenMlsContentKind::Application, ahead)
        .await
        .expect("alice's own row at the higher epoch")
}

#[tokio::test]
async fn a_current_epoch_orphan_row_neither_gates_nor_is_claimed_by_the_sweep() {
    // A row orphaned by a kill mid-ingest, or left `Retryable` by a decrypt that
    // can never succeed (an exhausted sender ratchet), at or below the group
    // tip: at MDK v0.10.4 it no longer gates the circle's sends, and Haven's
    // sweep must not claim it while the relay still holds its event.
    for state in [MessageState::Created, MessageState::Retryable] {
        let c = build_two_member_circle().await;
        send_and_receive(&c.alice, &c.bob, &c.mls_group_id, 37.77, -122.41).await;

        // A row Bob has NEVER delivered, sealed at his CURRENT epoch: Alice's
        // second send, which never reached him.
        let tip = c
            .bob
            .session()
            .epoch(&c.mls_group_id)
            .await
            .expect("bob's epoch");
        c.alice
            .seal_location_for_test(&c.mls_group_id, &LocationMessage::new(9.0, 9.0))
            .await
            .expect("alice's undelivered send");
        let orphan = c
            .alice
            .session()
            .stored_convergence_input_for_test(
                &c.mls_group_id,
                OpenMlsContentKind::Application,
                tip,
            )
            .await
            .expect("an application row at the current epoch");
        let orphan_id = c
            .bob
            .session()
            // NOT backdated: the sweep's age rule must not be able to claim
            // this row.
            .stage_convergence_input_for_test(&orphan, state, 0)
            .await
            .expect("stage the orphan");

        // Run the sweep FIRST, at the real wall clock, so the age rule is
        // exercised and provably DECLINES this row: a sweep that never ran
        // cannot be shown not to have retired anything.
        let swept = c
            .bob
            .sweep_unresolvable_inputs(
                u64::try_from(chrono::Utc::now().timestamp()).expect("a positive unix clock"),
            )
            .await
            .expect("sweep runs");
        assert_eq!(
            swept.disposed_messages, 0,
            "a row the relay still holds is not the sweep's to retire"
        );

        let sent = send_and_receive(&c.bob, &c.alice, &c.mls_group_id, 48.85, 2.35).await;
        assert_well_formed_445(&sent, c.nostr_group_id);
        assert_eq!(
            c.bob
                .session()
                .stored_message_record_for_test(&orphan_id)
                .await
                .expect("read the row")
                .map(|probe| probe.state),
            Some(state),
            "the {state:?} orphan did not stop the send, and nothing claimed it: \
             `Failed` would mean Haven's sweep took a row that was never its to take"
        );
    }
}

#[tokio::test]
async fn a_future_epoch_row_no_longer_gates_and_the_sweep_still_retires_it() {
    // An application row sealed one epoch above this device's tip is kept
    // `Retryable` on purpose, so the commit that would make it decryptable can
    // still arrive. At MDK v0.10.4 it does not gate the circle's sends while it
    // waits, through a restart too; once the relay can no longer redeliver it,
    // the sweep gives it its terminal disposition.
    let c = build_two_member_circle().await;
    send_and_receive(&c.alice, &c.bob, &c.mls_group_id, 37.77, -122.41).await;

    let ahead = alice_row_one_epoch_ahead(&c).await;
    let stuck = c
        .bob
        .session()
        .stage_convergence_input_for_test(&ahead, MessageState::Retryable, 0)
        .await
        .expect("stage the future-epoch row");
    let sent = c
        .bob
        .seal_location_for_test(&c.mls_group_id, &LocationMessage::new(51.5, -0.12))
        .await
        .expect("a lone future-epoch application row does not gate the send");
    assert_well_formed_445(&sent, c.nostr_group_id);

    let TwoMemberCircle {
        alice,
        bob,
        bob_keys,
        bob_dir,
        mls_group_id,
        nostr_group_id,
        ..
    } = c;
    drop(bob);
    let bob =
        CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).expect("bob's session reopens");
    assert_eq!(
        bob.session()
            .stored_message_record_for_test(&stuck)
            .await
            .expect("read the row")
            .map(|probe| probe.state),
        Some(MessageState::Retryable),
        "hydration must not resolve a future-epoch row — it is waiting for a commit"
    );

    // The sweep, run past the point where the relay still holds the event.
    let now = u64::try_from(chrono::Utc::now().timestamp()).expect("a positive unix clock")
        + UNRESOLVABLE_INPUT_MAX_AGE_SECS
        + 1;
    let sweep = bob
        .sweep_unresolvable_inputs(now)
        .await
        .expect("sweep runs");
    assert_eq!(
        sweep.disposed_messages, 1,
        "exactly the stuck row is retired"
    );
    assert!(
        sweep.is_settled(),
        "nothing may still gate outbound sends after the sweep"
    );
    assert_eq!(
        bob.session()
            .stored_message_record_for_test(&stuck)
            .await
            .expect("read the swept row")
            .map(|probe| probe.state),
        Some(MessageState::Failed),
        "the row must carry a TERMINAL disposition, not be deleted or left retryable"
    );

    let sent = send_and_receive(&bob, &alice, &mls_group_id, 48.85, 2.35).await;
    assert_well_formed_445(&sent, nostr_group_id);
}

#[tokio::test]
async fn a_future_epoch_row_past_the_horizon_is_retired_at_the_next_session_open() {
    // The force-stop-and-relaunch path: no explicit repair call, no Dart, just
    // the sweep that every session open runs.
    let c = build_two_member_circle().await;
    send_and_receive(&c.alice, &c.bob, &c.mls_group_id, 37.77, -122.41).await;

    let ahead = alice_row_one_epoch_ahead(&c).await;
    let stuck = c
        .bob
        .session()
        .stage_convergence_input_for_test(
            &ahead,
            MessageState::Retryable,
            UNRESOLVABLE_INPUT_MAX_AGE_SECS + 1,
        )
        .await
        .expect("stage a row the relay has already dropped");

    let TwoMemberCircle {
        alice,
        bob,
        bob_keys,
        bob_dir,
        mls_group_id,
        ..
    } = c;
    drop(bob);
    let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys)
        .expect("bob's session reopens on the same database");

    assert_eq!(
        bob.session()
            .stored_message_record_for_test(&stuck)
            .await
            .expect("read the swept row")
            .map(|probe| probe.state),
        Some(MessageState::Failed),
        "opening the session must retire a row the relay can no longer redeliver"
    );
    send_and_receive(&bob, &alice, &mls_group_id, 48.85, 2.35).await;
}

#[tokio::test]
async fn the_sweep_never_retires_a_commit_at_any_age() {
    let c = build_two_member_circle().await;

    // Give Bob a real INBOUND commit: Alice adds a third member, publishes the
    // evolution commit (confirmed on the ack Rule 13 requires), Bob applies it.
    let carol = new_member().await;
    let (added, _) = c
        .alice
        .add_members_for_test(&c.mls_group_id, &[carol.key_package])
        .await
        .expect("alice adds carol");
    c.bob
        .ingest_for_test(&added)
        .await
        .expect("bob applies the add commit");

    // Copy that commit into the state a kill mid-ingest leaves behind, stamped
    // a century before the wall clock — far past the retention horizon.
    let commit = c
        .bob
        .session()
        .stored_convergence_input_for_test(&c.mls_group_id, OpenMlsContentKind::Commit, 0)
        .await
        .expect("a stored commit row");
    let stuck_commit = c
        .bob
        .session()
        .stage_convergence_input_for_test(&commit, MessageState::Created, 100 * 365 * 24 * 60 * 60)
        .await
        .expect("stage a stuck commit row");

    let now = u64::try_from(chrono::Utc::now().timestamp()).expect("a positive unix clock");
    let sweep = c
        .bob
        .sweep_unresolvable_inputs(now)
        .await
        .expect("sweep runs");

    // Age must not be able to retire a commit: a relay never deletes one
    // (commits carry no NIP-40 tag) and a later delivery can genuinely resolve
    // it. Retiring it would strand this device at an epoch the group has left.
    assert_eq!(
        sweep.disposed_messages, 0,
        "no commit may ever be given a terminal disposition by the age rule"
    );
    assert_eq!(
        c.bob
            .session()
            .stored_message_record_for_test(&stuck_commit)
            .await
            .expect("read the commit row")
            .map(|probe| probe.state),
        Some(MessageState::Created),
        "the commit row must be left exactly as it was"
    );
    assert!(
        !sweep.is_settled(),
        "and it must still be reported as gating, so the stall stays visible"
    );

    // The consequence, stated at the sweep's own interface, which is what a
    // "repair sharing" affordance reads: the circle is still gating, so the
    // stall stays VISIBLE rather than being traded for a fork.
    //
    // The send path is deliberately not the oracle here. This fixture re-stages
    // a commit the device has already APPLIED, so a send would drive the
    // canonicalizer into replaying it and fail the engine's own epoch
    // validation — a state no production device reaches, and not the promise
    // under test. Synthesizing a commit that is both unapplied and permanently
    // unresolvable is not possible through public APIs: a genuine unapplied
    // commit is simply applied. What matters, and what is asserted above, is
    // that the age rule never touches one.
    assert!(
        sweep.gating_rows >= 1,
        "the un-retired commit must still be counted as gating"
    );
}
