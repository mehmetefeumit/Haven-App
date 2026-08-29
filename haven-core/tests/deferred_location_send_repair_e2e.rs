//! One stuck inbound row must not silently kill a circle's OUTBOUND sends —
//! and a deferred send must never strand a commit the engine staged.
//!
//! `cgka-engine`'s `do_send` does not encrypt while
//! `should_queue_outbound_intent` holds: it persists a `QueuedOutboundIntent`
//! and returns `SendResult::Queued`. That predicate is true for exactly two
//! reasons, and these tests cover both.
//!
//! # 1. A stored row the convergence gate cannot settle
//!
//! `has_unresolved_convergence_inputs` counts any stored message inside
//! `[epoch - max_rewind, epoch + max_rewind]` that is `Created` or `Retryable`.
//! A Haven circle's epoch only advances on a membership change, so for a stable
//! circle that window is its entire life.
//!
//! What actually stays stuck is narrower than it first appears, and these tests
//! pin the boundary rather than assuming it (all measured at MDK rev
//! `e391adc`):
//!
//! - a **current-epoch** application row is resolved by the engine ITSELF —
//!   but only at the next session open, where hydration re-runs canonicalization
//!   and writes the terminal `EpochInvalidated`. In-process it just gates.
//! - a **future-epoch** application row (`tip < source_epoch <= tip + max_rewind`)
//!   is kept `Retryable` deliberately, so the commit that would make it
//!   decryptable can still arrive — and it survives a session open unchanged.
//!   When that commit never comes, this is permanent, and the age-based sweep
//!   is the only thing that clears it.
//!
//! That distinction is why BOTH entry points exist: an Android foreground
//! reopen is not a process restart, so the runtime repair is what an unstuck
//! circle needs without one, and the session-open sweep is what a force-stop
//! and relaunch needs for the shape hydration cannot fix.
//!
//! # 2. A staged `SelfRemove` auto-commit
//!
//! `should_queue_outbound_intent` also returns true precisely when
//! `stage_due_self_remove_auto_commit` has just STAGED an eviction commit,
//! which `collect_effects` drains into the deferred send's own effects. That
//! `PendingStateRef` must be handed to the caller, never confirmed (applying a
//! commit no relay acked), never rolled back (the engine drops the retry
//! schedule and the leaver stays forever), and never dropped (the group stays
//! in `PendingPublish` and stops sending altogether).

use haven_core::circle::{CircleConfig, CircleError, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{
    ConvergedRoster, GroupId, LocationMessageResult, MessageRecord, MessageState,
    OpenMlsContentKind, UNRESOLVABLE_INPUT_MAX_AGE_SECS,
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
    alice_keys: Keys,
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
        .create_circle(&alice_keys, vec![bob.key_package], &config, &relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

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
        alice_keys,
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
    from_keys: &Keys,
    to: &CircleManager,
    group_id: &GroupId,
    lat: f64,
    lon: f64,
) -> (nostr::Event, [u8; 32], Vec<String>) {
    let sent = from
        .encrypt_location(
            group_id,
            &from_keys.public_key(),
            &LocationMessage::new(lat, lon),
            60,
        )
        .await
        .expect("the sender must encrypt rather than queue");
    let results = to
        .decrypt_location(&sent.0)
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

/// Sends one location and requires the engine to have DEFERRED it, returning
/// `(unresolved_inputs, discarded_intents, repaired, staged_commit_count)`.
async fn expect_deferred(
    manager: &CircleManager,
    keys: &Keys,
    group_id: &GroupId,
) -> (usize, usize, bool, usize) {
    let err = manager
        .encrypt_location(
            group_id,
            &keys.public_key(),
            &LocationMessage::new(51.5, -0.12),
            60,
        )
        .await
        .expect_err("a stuck convergence input must stop the engine encrypting");
    match err {
        CircleError::SendDeferred {
            unresolved_inputs,
            discarded_intents,
            repaired,
            work,
        } => (
            unresolved_inputs,
            discarded_intents,
            repaired,
            work.commits.len(),
        ),
        other => {
            panic!("a queued send must surface as SendDeferred, not an opaque error: {other:?}")
        }
    }
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
    let added = c
        .alice
        .add_members_with_welcomes(
            &c.alice_keys,
            &c.mls_group_id,
            vec![carol.key_package],
            &[GROUP_RELAY.to_string()],
        )
        .await
        .expect("alice stages the add");
    c.alice
        .confirm_published(added.pending)
        .await
        .expect("alice confirms the add on a relay ack");
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
        .encrypt_location(
            &c.mls_group_id,
            &c.alice_keys.public_key(),
            &LocationMessage::new(5.0, 6.0),
            60,
        )
        .await
        .expect("alice sends at the higher epoch");
    c.alice
        .session()
        .stored_convergence_input_for_test(&c.mls_group_id, OpenMlsContentKind::Application, ahead)
        .await
        .expect("alice's own row at the higher epoch")
}

#[tokio::test]
async fn the_engine_itself_clears_a_current_epoch_orphan_without_the_sweep() {
    // THE PREMISE, pinned — and the reason this unit's sweep is scoped the way
    // it is. A row orphaned by a kill mid-ingest, or left `Retryable` by a
    // decrypt that can never succeed (an exhausted sender ratchet), is NOT what
    // needs Haven's help when it sits at or below the group tip: the engine's
    // own canonicalization finds it undecryptable on the canonical branch and
    // writes the terminal `EpochInvalidated`
    // (`openmls_projection::message_state_for_invalidated_reason`), inside the
    // very `do_send` that hit it.
    //
    // If this test ever goes red, the sweep's scope is wrong — either it is
    // claiming rows that were never its to claim, or the engine has stopped
    // self-healing and the sweep needs to cover this shape too.
    for state in [MessageState::Created, MessageState::Retryable] {
        let c = build_two_member_circle().await;
        send_and_receive(
            &c.alice,
            &c.alice_keys,
            &c.bob,
            &c.mls_group_id,
            37.77,
            -122.41,
        )
        .await;

        // A row Bob has NEVER delivered, sealed at his CURRENT epoch: Alice's
        // second send, which never reached him.
        let tip = c
            .bob
            .session()
            .epoch(&c.mls_group_id)
            .await
            .expect("bob's epoch");
        c.alice
            .encrypt_location(
                &c.mls_group_id,
                &c.alice_keys.public_key(),
                &LocationMessage::new(9.0, 9.0),
                60,
            )
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
            // this row, so whatever clears it is provably the engine.
            .stage_convergence_input_for_test(&orphan, state, 0)
            .await
            .expect("stage the orphan");

        // Run the sweep FIRST, at the real wall clock, so the age rule is
        // exercised and provably DECLINES this row. Without this the second
        // half of the oracle below is unreachable: a sweep that never ran
        // cannot be shown not to have retired anything, so dropping the age
        // rule would leave this test green.
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

        let sent =
            send_and_receive(&c.bob, &c.bob_keys, &c.alice, &c.mls_group_id, 48.85, 2.35).await;
        assert_well_formed_445(&sent, c.nostr_group_id);
        assert_eq!(
            c.bob
                .session()
                .stored_message_state_for_test(&orphan_id)
                .await
                .expect("read the row"),
            Some(MessageState::EpochInvalidated),
            "the ENGINE must resolve a current-epoch {state:?} orphan; reading `Failed` \
             would mean Haven's sweep claimed a row that was never its to claim, and \
             reading {state:?} would mean this shape now needs the sweep too"
        );
    }
}

#[tokio::test]
async fn a_future_epoch_row_stays_stuck_across_a_reopen_and_only_the_sweep_clears_it() {
    // THE SHAPE THE SWEEP EXISTS FOR. An application row sealed one epoch above
    // this device's tip is kept `Retryable` on purpose, so the commit that would
    // make it decryptable can still arrive. When it never does, the row gates
    // every send for the circle forever — through restarts, because hydration
    // keeps it for the same reason.
    let c = build_two_member_circle().await;
    send_and_receive(
        &c.alice,
        &c.alice_keys,
        &c.bob,
        &c.mls_group_id,
        37.77,
        -122.41,
    )
    .await;

    let ahead = alice_row_one_epoch_ahead(&c).await;
    let stuck = c
        .bob
        .session()
        .stage_convergence_input_for_test(&ahead, MessageState::Retryable, 0)
        .await
        .expect("stage the future-epoch row");

    let (unresolved, discarded, repaired, staged) =
        expect_deferred(&c.bob, &c.bob_keys, &c.mls_group_id).await;
    assert_eq!(unresolved, 1, "the future-epoch row gates the send");
    assert_eq!(
        discarded, 1,
        "the ephemeral location intent the engine queued must be dropped, not banked"
    );
    assert!(
        !repaired,
        "convergence deliberately keeps this row retryable; only the age rule can retire it"
    );
    assert_eq!(staged, 0);
    assert_eq!(
        c.bob
            .session()
            .queued_intent_count_for_test(&c.mls_group_id)
            .await
            .expect("read the intent queue"),
        0,
        "the discarded intent must be gone from storage"
    );

    // A restart does not help — the distinguishing property of this shape.
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
            .stored_message_state_for_test(&stuck)
            .await
            .expect("read the row"),
        Some(MessageState::Retryable),
        "hydration must not resolve a future-epoch row — it is waiting for a commit"
    );
    let (_, _, repaired_after_restart, _) = expect_deferred(&bob, &bob_keys, &mls_group_id).await;
    assert!(
        !repaired_after_restart,
        "this is the shape that survives the force-stop-and-relaunch the owner tried"
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
            .stored_message_state_for_test(&stuck)
            .await
            .expect("read the swept row"),
        Some(MessageState::Failed),
        "the row must carry a TERMINAL disposition, not be deleted or left retryable"
    );

    let sent = send_and_receive(&bob, &bob_keys, &alice, &mls_group_id, 48.85, 2.35).await;
    assert_well_formed_445(&sent, nostr_group_id);
}

#[tokio::test]
async fn a_future_epoch_row_past_the_horizon_is_retired_at_the_next_session_open() {
    // The force-stop-and-relaunch path: no explicit repair call, no Dart, just
    // the sweep that every session open runs.
    let c = build_two_member_circle().await;
    send_and_receive(
        &c.alice,
        &c.alice_keys,
        &c.bob,
        &c.mls_group_id,
        37.77,
        -122.41,
    )
    .await;

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
            .stored_message_state_for_test(&stuck)
            .await
            .expect("read the swept row"),
        Some(MessageState::Failed),
        "opening the session must retire a row the relay can no longer redeliver"
    );
    send_and_receive(&bob, &bob_keys, &alice, &mls_group_id, 48.85, 2.35).await;
}

#[tokio::test]
async fn the_sweep_never_retires_a_commit_at_any_age() {
    let c = build_two_member_circle().await;

    // Give Bob a real INBOUND commit: Alice adds a third member, publishes the
    // evolution commit (confirmed on the ack Rule 13 requires), Bob applies it.
    let carol = new_member().await;
    let added = c
        .alice
        .add_members_with_welcomes(
            &c.alice_keys,
            &c.mls_group_id,
            vec![carol.key_package],
            &[GROUP_RELAY.to_string()],
        )
        .await
        .expect("alice stages the add");
    c.alice
        .confirm_published(added.pending)
        .await
        .expect("alice confirms the add");
    c.bob
        .decrypt_location(&added.commit_event)
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
            .stored_message_state_for_test(&stuck_commit)
            .await
            .expect("read the commit row"),
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

#[tokio::test]
async fn a_deferral_that_staged_an_eviction_commit_hands_it_back_unresolved() {
    // Rule 13 on the send path. `should_queue_outbound_intent` returns true
    // PRECISELY when `stage_due_self_remove_auto_commit` just staged a peer's
    // eviction, and `collect_effects` drains that commit into the deferred
    // send's own effects. Confirming it would apply a commit no relay acked;
    // rolling it back would lose the engine's retry schedule and strand the
    // leaver forever; dropping it would pin the group in `PendingPublish` and
    // stop sending entirely. It must come back to the caller intact.
    let c = build_two_member_circle().await;
    let bob_hex = c.bob_keys.public_key().to_hex();

    let proposal = c
        .bob
        .propose_leave(&c.mls_group_id)
        .await
        .expect("bob proposes leave");
    // Raw ingest: `decrypt_location_collecting_commits` would re-tick
    // convergence and drain the auto-commit itself, which is the path this test
    // is NOT about.
    c.alice
        .session()
        .process_event(&proposal)
        .await
        .expect("alice ingests the self-remove proposal");

    // The engine schedules the auto-commit with a 10–50 ms jitter, so the first
    // send after the proposal may still encrypt normally. Retry until the
    // deferral appears — a bounded loop on a monotonic clock that always
    // advances, exactly like the production re-tick in
    // `decrypt_location_collecting_commits`. No sleep, and the bound is
    // asserted rather than assumed.
    let mut staged = None;
    for _ in 0..5_000 {
        match c
            .alice
            .encrypt_location(
                &c.mls_group_id,
                &c.alice_keys.public_key(),
                &LocationMessage::new(1.0, 2.0),
                60,
            )
            .await
        {
            Ok(_) => {}
            Err(CircleError::SendDeferred { work, .. }) => {
                staged = Some(work);
                break;
            }
            Err(other) => panic!("unexpected send failure: {other:?}"),
        }
    }
    let work = staged.expect(
        "the due self-remove auto-commit must surface as a deferred send within the \
         engine's 50 ms jitter window",
    );
    assert_eq!(
        work.commits.len(),
        1,
        "the staged eviction commit must be handed back, not swallowed"
    );
    assert_eq!(
        c.alice
            .session()
            .queued_intent_count_for_test(&c.mls_group_id)
            .await
            .expect("read the intent queue"),
        0,
        "the location fix the engine queued to trigger this deferral must be discarded \
         here too — banking it until the next session open is the stale-position leak \
         `SendDeferred` promises not to have"
    );

    // The commit must be exactly where the engine left it: STAGED, with its
    // `PendingStateRef` still live. `confirm_published` is the oracle, because
    // its contract is precisely "errors if the pending ref is unknown —
    // already confirmed, rolled back, or never issued". That single call
    // therefore rules out BOTH wrong dispositions at once:
    //
    // - confirmed inside the repair → the ref is spent, and this errors;
    // - rolled back inside the repair → the ref is discarded, and this errors;
    // - left staged (correct) → this succeeds and the eviction lands.
    //
    // `epoch()` and the roster verdict are deliberately NOT the oracle: the
    // engine already reports the projected post-staging epoch and roster while
    // the commit is merely staged, so neither says anything about whether the
    // ref was resolved behind the caller's back.
    let commit = work.commits.into_iter().next().expect("one staged commit");
    c.alice.confirm_published(commit.pending).await.expect(
        "the deferred send must hand the staged eviction back UNRESOLVED: confirming it \
             applies a commit no relay acked, and rolling it back drops the engine's \
             self-remove schedule (it is removed before staging and never re-armed) so the \
             leaver never leaves",
    );

    let roster = match c
        .alice
        .session()
        .converged_member_pubkeys(&c.mls_group_id)
        .await
        .expect("roster after confirm")
    {
        ConvergedRoster::Converged {
            member_pubkeys_hex, ..
        } => member_pubkeys_hex,
        other => panic!("the group must be converged after the confirm: {other:?}"),
    };
    assert!(
        !roster.contains(&bob_hex),
        "confirming the handed-back commit must actually evict the leaver"
    );
}
