//! The durable fanout driver in one process (Security Rule 13).
//!
//! A commit staged in staging mode gets its durable MDK fanout row inside the
//! session-lock hold that staged it; [`drive_one`] sends the frozen event,
//! confirms on the first relay acknowledgement and never before, and rolls
//! back only when every relay proved it did not take the commit and none was
//! ever possibly exposed. No path but the driver resolves such a commit or
//! sends its event.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted
//! ([`ScriptedFanout`]) and sends nothing, so no relay is ever dialled. The
//! only real time paid is the engine's own announced deadline in the tests
//! that need a received proposal or commit applied
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

mod helpers;

use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::nostr::mls::storage::{
    set_engine_write_fault_for_test, set_stored_message_write_fault_for_test, EngineWrite,
};
use haven_core::nostr::mls::types::{
    ConvergedRoster, EpochState, FanoutId, FanoutMls, FanoutProbe, FanoutTargetStatus, GroupId,
    MessageId, MessageState, PendingStateRef, PublishWork, ScreenedIngest, Staged,
};
use haven_core::nostr::mls::{SessionManager, StorageConfig};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::UnrecordedPublisher as _;
use haven_core::relay::fanout::{
    disown_for_test, drive_one, is_owned, DriveMode, FanoutClock, FanoutStatus, LocationSeal,
    SendHeld,
};
use haven_core::relay::{RelayError, RelayManager};
use helpers::{assert_no_needles, capture_haven_log, setup_circle, CircleFixture, CircleMember};
use nostr::JsonUtil as _;

const JOINER_INBOX: &str = "wss://joiner-inbox.example.com";
const ONE: &str = "wss://one.fanout-canary7f3a.example.com";
const TWO: &str = "wss://two.fanout-canary7f3a.example.com";
const THREE: &str = "wss://three.fanout-canary7f3a.example.com";

/// A clock a test sets.
struct Clock(AtomicU64);

impl FanoutClock for Clock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

const STAGED_AT: u64 = 1_700_000_000_000;

const fn clock() -> Clock {
    Clock(AtomicU64::new(STAGED_AT))
}

/// Stages the removal of the circle's last member in staging mode.
async fn stage_removal(fx: &CircleFixture) -> FanoutId {
    let last = fx.members.last().expect("a member").pubkey_hex();
    let staged = fx
        .admin()
        .session()
        .remove_members_staging(&fx.group, &[last], STAGED_AT)
        .await
        .expect("the removal is staged");
    the_one_fanout(staged)
}

fn the_one_fanout(staged: Staged) -> FanoutId {
    assert!(
        !staged.effects.publish.iter().any(|work| matches!(
            work,
            PublishWork::GroupEvolution { .. } | PublishWork::AutoPublish { .. }
        )),
        "a staging-mode call handed a commit back as publish work",
    );
    let [id] = <[FanoutId; 1]>::try_from(staged.fanouts)
        .unwrap_or_else(|_| panic!("the call staged exactly one commit"));
    id
}

async fn probe(member: &CircleMember, id: &FanoutId) -> Option<FanoutProbe> {
    member
        .session()
        .fanout_probe_for_test(id)
        .await
        .expect("the store is read")
}

async fn row(member: &CircleMember, id: &FanoutId) -> FanoutProbe {
    probe(member, id).await.expect("the fanout row exists")
}

async fn staged_ref(member: &CircleMember, group: &GroupId) -> Option<PendingStateRef> {
    match member.session().epoch_state(group).await {
        Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
        _ => None,
    }
}

async fn commit_row_state(member: &CircleMember, row: &FanoutProbe) -> Option<MessageState> {
    member
        .session()
        .stored_message_record_for_test(&MessageId::new(row.event_id.to_bytes().to_vec()))
        .await
        .expect("the store is read")
        .map(|record| record.state)
}

async fn settled_member_count(member: &CircleMember, group: &GroupId) -> Option<usize> {
    match member
        .session()
        .converged_member_pubkeys(group)
        .await
        .expect("the roster is read")
    {
        ConvergedRoster::Converged {
            member_pubkeys_hex, ..
        } => Some(member_pubkeys_hex.len()),
        ConvergedRoster::NotConverged | ConvergedRoster::Absent => None,
    }
}

fn answering(answers: &[(&str, &[Answer])]) -> ScriptedFanout {
    let transport = ScriptedFanout::default();
    for (target, script) in answers {
        transport.answer(target, script.iter().copied());
    }
    transport
}

/// A clock no relay is still waiting on: each one reads an hour after the
/// last this test took — the longest a relay is ever left alone for — and,
/// counted per test, stays inside the day after which a record's bound would
/// end it.
fn later() -> Clock {
    thread_local! {
        static NOW: std::cell::Cell<u64> = const { std::cell::Cell::new(STAGED_AT) };
    }
    const HOUR_MS: u64 = 60 * 60 * 1_000;
    Clock(AtomicU64::new(NOW.with(|now| {
        now.set(now.get() + HOUR_MS);
        now.get()
    })))
}

/// One drive, at a time every relay the row still owes is due again.
async fn drive(fx: &CircleFixture, transport: &ScriptedFanout, id: &FanoutId) -> FanoutStatus {
    drive_one(
        &fx.admin().circle,
        transport,
        &later(),
        id,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs")
    .status
}

// ── Staging ──────────────────────────────────────────────────────────────────

/// The record is stored before any relay is written to, and each target is
/// stored `Attempting` before its own write.
#[tokio::test]
async fn fanout_record_durable_before_first_write() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;

    let staged = row(fx.admin(), &id).await;
    assert_eq!(staged.mls, FanoutMls::Pending);
    assert_eq!(staged.targets, [ONE, TWO]);
    assert_eq!(
        staged.statuses,
        [FanoutTargetStatus::NotAttempted; 2],
        "nothing has been attempted, and the row already exists",
    );
    assert_eq!(staged.created_at_ms, STAGED_AT);
    assert!(
        staged_ref(fx.admin(), &fx.group).await.is_some(),
        "premise: the engine holds the commit staged",
    );

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    transport.park();
    let clock = clock();
    let driving = drive_one(
        &fx.admin().circle,
        &transport,
        &clock,
        &id,
        &DriveMode::Full,
    );
    tokio::pin!(driving);
    tokio::select! {
        biased;
        _ = &mut driving => panic!("the drive finished while its calls were parked"),
        () = transport.parked() => {}
    }
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [FanoutTargetStatus::Attempting; 2],
        "a relay was written to before its target was stored as being attempted",
    );
    assert!(
        staged_ref(fx.admin(), &fx.group).await.is_some(),
        "the commit was applied before any relay answered",
    );
    transport.unpark();
    assert_eq!(
        driving.await.expect("the drive runs").status,
        FanoutStatus::Confirmed
    );
    let sent = transport.calls();
    assert_eq!(sent.len(), 2, "each relay is written to once");
    assert!(
        sent.iter()
            .all(|call| call.event_id == staged.event_id && call.payload == staged.payload),
        "what was sent is not the frozen event, byte for byte",
    );
}

/// The row is written in the lock hold that stages the commit: a reader queued
/// behind that hold never finds the commit staged without it.
///
/// Deterministic by the lock's fairness. The test holds the session lock, the
/// staging call queues behind it and then the reader behind that; released,
/// they run in that order. Were the row written in a second hold, the reader
/// would be served between the two and see the commit with no row.
#[tokio::test(flavor = "current_thread")]
async fn a_commit_is_never_staged_without_its_fanout_row() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let session = fx.admin().session();
    let last = [fx.members[2].pubkey_hex()];

    let held = session.hold_session_for_test().await;
    let (staged, seen_without_row, ()) = tokio::join!(
        session.remove_members_staging(&fx.group, &last, STAGED_AT),
        async {
            (
                session.staged_without_fanout_for_test(&fx.group).await,
                session.epoch_state(&fx.group).await,
            )
        },
        async { drop(held) },
    );
    the_one_fanout(staged.expect("the removal is staged"));
    assert!(
        matches!(seen_without_row.1, Some(EpochState::PendingPublish(_))),
        "premise: the reader ran after the commit was staged",
    );
    assert!(
        !seen_without_row.0,
        "a commit was staged in one lock hold and its fanout row written in \
         another: a kill between them leaves a commit no restart recovers",
    );
}

/// A commit whose row cannot be written is rolled back in the same hold, and
/// its own stored row retired: nothing had left the device.
#[tokio::test]
async fn a_commit_whose_row_cannot_be_written_is_rolled_back_at_once() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(admin.dir.path()).database_path();
    let before = admin.session().epoch(&fx.group).await.expect("epoch");

    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    let mut staged = None;
    let lines = capture_haven_log(async {
        staged = Some(
            admin
                .session()
                .remove_members_staging(&fx.group, &[fx.members[2].pubkey_hex()], STAGED_AT)
                .await,
        );
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");

    let staged = staged
        .expect("the call ran")
        .expect("a commit that could not be recorded is undone, not an error");
    assert!(staged.fanouts.is_empty(), "no row was written");
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && !admin
                .session()
                .staged_without_fanout_for_test(&fx.group)
                .await,
        "the commit was left staged with no row",
    );
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before
    );
    assert_eq!(
        settled_member_count(admin, &fx.group).await,
        Some(3),
        "the removal it carried must not have happened",
    );
    let line = lines
        .iter()
        .find(|line| {
            line.message
                .contains("could not be recorded and is rolled back")
        })
        .expect("the undone commit is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(fx.group.as_slice()),
            &admin.pubkey_hex(),
            &fx.members[2].pubkey_hex(),
            "fanout-canary7f3a",
        ],
    );

    // The circle is usable again at once: the same removal stages and confirms.
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
    assert_eq!(settled_member_count(admin, &fx.group).await, Some(2));
}

/// A relay-list change is frozen for the relays of the epoch it leaves.
#[tokio::test]
async fn routing_change_commit_targets_prior_relays() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let moved = "wss://moved.fanout-canary7f3a.example.com";
    let staged = fx
        .admin()
        .session()
        .update_relays_staging(&fx.group, vec![moved.to_string()], STAGED_AT)
        .await
        .expect("the relay change is staged");
    let id = the_one_fanout(staged);
    assert_eq!(
        row(fx.admin(), &id).await.targets,
        [ONE, TWO],
        "a routing change must reach the members where they are still listening",
    );

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Refused])]);
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
    assert_eq!(
        fx.admin()
            .session()
            .group_relays(&fx.group)
            .await
            .expect("relays"),
        [moved],
        "premise: the change took effect once confirmed",
    );
    // The next commit leaves the new epoch, so it goes to the new relay.
    let next = the_one_fanout(
        fx.admin()
            .session()
            .update_relays_staging(&fx.group, vec![ONE.to_string()], STAGED_AT)
            .await
            .expect("a second relay change is staged"),
    );
    assert_eq!(row(fx.admin(), &next).await.targets, [moved]);
}

/// `min(2, n)` over DISTINCT relays, frozen at staging.
#[tokio::test]
async fn the_staged_request_freezes_min_2_n_as_its_required_acks() {
    let three = "wss://three.fanout-canary7f3a.example.com";
    // The same relay as ONE under another spelling: the component is unique
    // by bytes only.
    let one_again = "wss://one.fanout-canary7f3a.example.com:443";
    for (relays, expected) in [
        (vec![ONE], 1),
        (vec![ONE, TWO], 2),
        (vec![ONE, TWO, three], 2),
        (vec![ONE, one_again], 1),
    ] {
        let fx = setup_circle(2, &relays).await;
        let id = stage_removal(&fx).await;
        let staged = row(fx.admin(), &id).await;
        let mut named = relays.clone();
        named.sort_unstable();
        assert_eq!(staged.targets, named, "premise: every entry is frozen");
        assert_eq!(
            staged.required_acks, expected,
            "the acknowledgements a fanout asks for are min(2, distinct relays)",
        );
    }
}

/// A Welcome is frozen in the commit's row at staging, not handed back.
#[tokio::test]
async fn an_invites_welcomes_are_frozen_in_its_commits_row() {
    let fx = setup_circle(2, &[ONE]).await;
    let joiner = CircleMember::new();
    let package = SessionManager::key_package_from_event(
        &helpers::create_key_package_event(joiner.session(), &joiner.keys, &[ONE.to_string()])
            .await,
    )
    .expect("a key package");
    let staged = fx
        .admin()
        .session()
        .add_members_staging(&fx.group, vec![package], STAGED_AT)
        .await
        .expect("the invite is staged");
    let id = the_one_fanout(staged);
    assert_eq!(
        row(fx.admin(), &id).await.held_welcomes,
        1,
        "the Welcome must wait in the row for its commit's confirm",
    );
}

/// A routing entry Haven may not dial is another client's to have written. It
/// is left out of the frozen targets: frozen, it could only ever be answered
/// "refused before the hand-over", and it is not a relay for the count.
#[tokio::test]
async fn a_routing_entry_haven_may_not_dial_is_never_frozen_as_a_target() {
    use cgka_traits::app_components::{
        encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
    };
    use haven_core::nostr::mls::types::{AppComponentData, SendIntent};

    let fx = setup_circle(2, &[ONE]).await;
    let session = fx.admin().session();
    // Written straight to the engine, past Haven's own validation, as another
    // client's admin would write it.
    let (nostr_group_id, _) = session.group_routing(&fx.group).await.expect("routing");
    let refused = "ws://refused-entry.invalid";
    let mut named = vec![ONE.to_string(), TWO.to_string(), refused.to_string()];
    named.sort();
    let routing = NostrRoutingV1::new(nostr_group_id, named).expect("MDK admits ws and wss");
    let foreign = session
        .send(SendIntent::UpdateAppComponents {
            group_id: fx.group.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(&routing).expect("the component encodes"),
            }],
        })
        .await
        .expect("the routing change is staged");
    let pending = foreign
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { pending, .. } => Some(*pending),
            _ => None,
        })
        .expect("one commit");
    session.confirm_published(pending).await.expect("applied");
    assert_eq!(
        session.group_relays(&fx.group).await.expect("relays").len(),
        3,
        "premise: the component names the refused relay",
    );

    let id = stage_removal(&fx).await;
    let staged = row(fx.admin(), &id).await;
    assert_eq!(staged.targets, [ONE, TWO]);
    assert_eq!(staged.required_acks, 2);
}

// ── The decision rule ────────────────────────────────────────────────────────

/// Rolled back only when EVERY relay proved it did not take the commit;
/// confirmed on the first acknowledgement; otherwise left staged.
#[tokio::test]
async fn publish_failed_only_when_no_target_could_accept() {
    use Answer::{Accepted, NotExposed, RateLimited, Refused, Silent, Unreachable};
    let cases = [
        (Refused, Refused, FanoutStatus::RolledBack),
        (Refused, NotExposed, FanoutStatus::RolledBack),
        (NotExposed, NotExposed, FanoutStatus::RolledBack),
        (Refused, Silent, FanoutStatus::Unresolved),
        (Refused, Unreachable, FanoutStatus::Unresolved),
        (Refused, RateLimited, FanoutStatus::Unresolved),
        (Silent, Silent, FanoutStatus::Unresolved),
        (Unreachable, Unreachable, FanoutStatus::Unresolved),
        (Accepted, Refused, FanoutStatus::Confirmed),
        (Silent, Accepted, FanoutStatus::Confirmed),
    ];
    // A rolled-back removal leaves the circle as it was, so those cases share
    // one; every other outcome uses the circle up.
    let mut reusable = Some(setup_circle(2, &[ONE, TWO]).await);
    for (one, two, expected) in cases {
        let fx = match reusable.take() {
            Some(fx) => fx,
            None => setup_circle(2, &[ONE, TWO]).await,
        };
        let before = fx.admin().session().epoch(&fx.group).await.expect("epoch");
        let id = stage_removal(&fx).await;
        let transport = answering(&[(ONE, &[one]), (TWO, &[two])]);

        let status = drive(&fx, &transport, &id).await;
        assert_eq!(status, expected, "for answers {one:?} and {two:?}");
        let staged = staged_ref(fx.admin(), &fx.group).await.is_some();
        let members = settled_member_count(fx.admin(), &fx.group).await;
        assert_eq!(transport.calls().len(), 2, "one call per relay, no retry");
        match expected {
            FanoutStatus::Confirmed => {
                assert_eq!(members, Some(1), "the confirmed removal took effect");
                assert_eq!(
                    fx.admin().session().epoch(&fx.group).await.expect("epoch"),
                    before + 1
                );
            }
            FanoutStatus::RolledBack => {
                assert_eq!(members, Some(2), "the rolled-back removal did not happen");
                assert!(
                    probe(fx.admin(), &id).await.is_none(),
                    "a rolled-back fanout's row is gone",
                );
                reusable = Some(fx);
            }
            _ => {
                assert!(staged, "an unresolved commit stays staged");
                assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::Pending);
            }
        }
    }
}

#[tokio::test]
async fn a_timeout_keeps_the_commit_pending() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);

    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Unresolved);
    let stored = row(fx.admin(), &id).await;
    assert_eq!(stored.mls, FanoutMls::Pending);
    assert_eq!(stored.statuses, [FanoutTargetStatus::PossiblyExposed; 2]);
    assert!(staged_ref(fx.admin(), &fx.group).await.is_some());
    assert_eq!(
        commit_row_state(fx.admin(), &stored).await,
        Some(MessageState::Sent),
        "a commit a relay may hold is never retired",
    );
}

/// The relay stored the commit and its `OK` was lost. Another relay's proven
/// refusal must not undo it, and the same bytes sent again are acknowledged.
#[tokio::test]
async fn a_lost_ok_is_never_rolled_back_and_the_commit_applies_when_the_ack_arrives() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let transport = answering(&[
        (ONE, &[Answer::Silent, Answer::Accepted]),
        (TWO, &[Answer::Refused]),
    ]);

    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Unresolved);
    assert!(staged_ref(fx.admin(), &fx.group).await.is_some());
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [
            FanoutTargetStatus::PossiblyExposed,
            FanoutTargetStatus::Failed
        ],
    );
    assert_eq!(transport.calls().len(), 2);

    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
    let again = transport.calls();
    assert_eq!(
        again.len(),
        1,
        "the relay that refused is not written to again"
    );
    assert_eq!(again[0].target, ONE);
    assert!(
        again[0].event_id == frozen.event_id && again[0].payload == frozen.payload,
        "the retry is not the frozen event, byte for byte",
    );
    assert_eq!(settled_member_count(fx.admin(), &fx.group).await, Some(1));
    assert!(
        probe(fx.admin(), &id).await.is_none(),
        "an applied commit's record outlived its last relay: one took it, the \
         other refused it for good",
    );
}

/// Exposure is never forgotten: a relay that may hold the commit and LATER
/// proves a refusal still forbids the rollback, however often it is driven.
#[tokio::test]
async fn a_rollback_never_retires_a_commit_a_relay_may_hold() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[
        (ONE, &[Answer::Silent, Answer::Refused]),
        (TWO, &[Answer::Refused]),
    ]);

    for _ in 0..4 {
        assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Unresolved);
        let stored = row(fx.admin(), &id).await;
        assert_eq!(stored.mls, FanoutMls::Pending);
        assert!(
            staged_ref(fx.admin(), &fx.group).await.is_some(),
            "a commit a relay may hold was rolled back",
        );
        assert_eq!(
            commit_row_state(fx.admin(), &stored).await,
            Some(MessageState::Sent),
            "a commit a relay may hold was retired",
        );
    }
    assert_eq!(settled_member_count(fx.admin(), &fx.group).await, None);
}

/// Two frozen spellings of one relay are one relay: it is written to once,
/// and its answer is the answer of both.
#[tokio::test]
async fn a_second_spelling_of_a_relay_is_never_sent_to_again() {
    let one_again = "wss://one.fanout-canary7f3a.example.com:443";
    let fx = setup_circle(2, &[ONE, one_again]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Silent, Answer::Accepted])]);
    transport.answer(one_again, [Answer::Refused]);

    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Unresolved);
    let sent = transport.calls();
    assert_eq!(sent.len(), 1, "one relay was written to twice");
    assert_eq!(sent[0].target, ONE);
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [FanoutTargetStatus::PossiblyExposed; 2],
        "the second spelling did not take the first one's answer",
    );

    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
    assert_eq!(transport.calls().len(), 1);
    // Both spellings took that one acknowledgement — nothing is left to
    // send, so the record has ended — and they were one relay's: the one
    // acknowledgement such a record was frozen to need.
    assert!(probe(fx.admin(), &id).await.is_none());
    assert_eq!(settled_member_count(fx.admin(), &fx.group).await, Some(1));
}

// ── One sender, one call, every outcome stored ───────────────────────────────

/// A drive whose future is dropped mid-call leaves its targets `Attempting`;
/// the next drive stores them possibly exposed BEFORE it tries again — so
/// three refusals afterwards prove nothing about the call that never returned.
#[tokio::test]
async fn a_call_that_never_returned_is_possibly_exposed_before_it_is_tried_again() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    transport.park();
    {
        let clock = clock();
        let driving = drive_one(
            &fx.admin().circle,
            &transport,
            &clock,
            &id,
            &DriveMode::Full,
        );
        tokio::pin!(driving);
        tokio::select! {
            biased;
            _ = &mut driving => panic!("the drive finished while its calls were parked"),
            () = transport.parked() => {}
        }
        // Dropped here, with both calls made and neither answered.
    }
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [FanoutTargetStatus::Attempting; 2],
        "premise: the dropped drive left its attempts stored as begun",
    );
    transport.unpark();
    let _ = transport.calls();

    let mut status = None;
    let lines = capture_haven_log(async {
        status = Some(drive(&fx, &transport, &id).await);
    })
    .await;
    assert_eq!(
        status,
        Some(FanoutStatus::Unresolved),
        "every relay refused the SECOND call, and the commit was rolled back \
         although the first call's frames were never answered",
    );
    let line = lines
        .iter()
        .find(|line| line.message.contains("an attempt that never returned"))
        .expect("an interrupted attempt is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(fx.group.as_slice()),
            &fx.admin().pubkey_hex(),
            "fanout-canary7f3a",
        ],
    );
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [FanoutTargetStatus::PossiblyExposed; 2],
    );
    assert!(staged_ref(fx.admin(), &fx.group).await.is_some());
    assert_eq!(
        transport.calls().len(),
        2,
        "each relay was tried again, once"
    );
}

/// One drive per row at a time: a second finds it taken and sends nothing.
#[tokio::test]
async fn two_drives_of_one_fanout_never_overlap() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    transport.park();
    let clock = clock();
    let first = drive_one(
        &fx.admin().circle,
        &transport,
        &clock,
        &id,
        &DriveMode::Full,
    );
    tokio::pin!(first);
    tokio::select! {
        biased;
        _ = &mut first => panic!("the drive finished while its calls were parked"),
        () = transport.parked() => {}
    }

    // A second drive that got in would park a call of its own.
    let second = tokio::select! {
        biased;
        status = drive(&fx, &transport, &id) => Some(status),
        () = transport.parked() => None,
    };
    assert_eq!(
        second,
        Some(FanoutStatus::Busy),
        "a second drive of the same row ran beside the first",
    );
    assert_eq!(transport.call_count(), 2, "the second drive sent something");

    transport.unpark();
    assert_eq!(
        first.await.expect("the drive runs").status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        transport.most_at_once(),
        1,
        "one event was under way to one relay more than once at a time",
    );
    // The row is free again once the drive has ended — and, both relays
    // holding the commit, so has the row.
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Gone);
}

/// No other publish path of any relay manager sends an event that has a
/// fanout row — while the row exists, and again after a restart.
#[tokio::test]
async fn nothing_but_the_driver_sends_an_event_that_has_a_fanout_row() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let event = nostr::Event::from_json(&frozen.payload).expect("the frozen event");
    let targets = [ONE.to_string(), TWO.to_string()];
    // Every publish path of a fresh relay manager refuses the event and
    // registers no relay for it.
    let refused = || {
        let (event, targets) = (event.clone(), targets.clone());
        async move {
            let relays = RelayManager::new();
            let ladder = relays.publish_event(&event, &targets).await;
            let profile = relays.publish_profile_event(&event, &targets).await;
            let location = relays.publish_location_event(&event, &targets).await;
            let background = relays.publish_event_background(event.clone(), &targets);
            let legacy_ladder = relays.publish_unrecorded(&event, &targets).await;
            matches!(ladder, Err(RelayError::FanoutOwned))
                && matches!(profile, Err(RelayError::FanoutOwned))
                && matches!(location, Err(RelayError::FanoutOwned))
                && matches!(background, Err(RelayError::FanoutOwned))
                && !legacy_ladder
                && relays.get_relay_status().await.is_empty()
        }
    };

    assert!(is_owned(&event.id));
    assert!(
        refused().await,
        "another publish path sent, or registered a relay for, an event that \
         has a fanout row",
    );

    // A new process knows nothing until its session opens the store.
    let mut members = fx.members;
    let admin = members.remove(0);
    disown_for_test(&event.id);
    assert!(!is_owned(&event.id), "premise: the registry was emptied");
    let admin = admin.reopen();
    assert!(
        refused().await,
        "after a restart the row's event was no longer the driver's alone",
    );

    // Once the row has ended, the event is nobody's.
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    let status = drive_one(&admin.circle, &transport, &clock(), &id, &DriveMode::Full)
        .await
        .expect("the drive runs")
        .status;
    assert_eq!(status, FanoutStatus::RolledBack);
    assert!(!is_owned(&event.id));
    assert!(
        !matches!(
            RelayManager::new()
                .publish_location_event(&event, &[])
                .await,
            Err(RelayError::FanoutOwned)
        ),
        "an event whose row is gone is refused as if it still had one",
    );
}

// ── No other path resolves the commit ────────────────────────────────────────

#[tokio::test]
async fn a_commit_under_a_fanout_is_never_resolved_but_by_the_driver() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let pending = staged_ref(fx.admin(), &fx.group)
        .await
        .expect("the commit is staged");

    // The session's own resolvers refuse it, whoever calls them — which is
    // what keeps the fold's internal rollback from discarding it.
    let session = fx.admin().session();
    assert!(matches!(
        session.confirm_published(pending).await,
        Err(haven_core::nostr::NostrError::FanoutOwned)
    ));
    assert!(matches!(
        session.publish_failed(pending).await,
        Err(haven_core::nostr::NostrError::FanoutOwned)
    ));
    assert!(matches!(
        session.publish_failed_on_receive(pending).await,
        Err(haven_core::nostr::NostrError::FanoutOwned)
    ));
    assert_eq!(
        staged_ref(fx.admin(), &fx.group).await,
        Some(pending),
        "a refused resolver changed the commit",
    );
    assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::Pending);

    // The driver still resolves it.
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
}

/// A pending row whose commit was resolved behind the driver's back is not a
/// licence to confirm whatever is staged later. MDK's hydrate binds the first
/// pending row of a group to the staged commit without matching them — so the
/// open removes the stale row before the engine hydrates, and the removal a
/// kill left staged is restored under a row that names it.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_stale_pending_row_is_never_bound_to_a_later_staged_commit_on_reopen() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let group = fx.group.clone();
    let stale = the_one_fanout(
        fx.admin()
            .session()
            .update_relays_staging(&group, vec![ONE.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged"),
    );
    let stale_event = row(fx.admin(), &stale).await.event_id;
    // Resolved by the engine call directly, past the driver and past both
    // refusals: the row stays pending.
    let first = staged_ref(fx.admin(), &group).await.expect("staged");
    fx.admin()
        .session()
        .confirm_published_past_its_fanout_for_test(first)
        .await
        .expect("the bypass applies the first commit");
    assert_eq!(row(fx.admin(), &stale).await.mls, FanoutMls::Pending);
    let after_first = fx.admin().session().epoch(&group).await.expect("epoch");

    // A second commit, staged with no row of its own, and a kill.
    let last = fx.members[2].pubkey_hex();
    let removal = commit_event_id(
        &fx.admin()
            .session()
            .remove_members(&group, &[last])
            .await
            .expect("a removal is staged the legacy way"),
    );
    let mut members = fx.members;
    let admin = members.remove(0);
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");

    assert_eq!(
        row(&admin, &stale).await.mls,
        FanoutMls::Confirmed,
        "the stale row was still pending at the open, where hydrate binds a \
         pending row to the removal",
    );
    let mut ids = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("ids");
    ids.retain(|id| *id != stale);
    let [own] = <[FanoutId; 1]>::try_from(ids)
        .unwrap_or_else(|_| panic!("the staged removal has exactly one row"));
    let held = row(&admin, &own).await;
    assert_eq!(
        held.event_id, removal,
        "the staged removal is held under a row that is not its own",
    );
    assert_eq!(held.targets, [ONE]);
    assert!(staged_ref(&admin, &group).await.is_some());

    // The first commit is applied on this device and its record says so: its
    // relays are sent THAT commit, and their acknowledgements confirm nothing
    // else.
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let status = drive_one(
        &admin.circle,
        &transport,
        &clock(),
        &stale,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs")
    .status;
    assert_eq!(status, FanoutStatus::Confirmed);
    assert!(
        transport
            .calls()
            .iter()
            .all(|call| call.event_id == stale_event),
        "the applied commit's record sent some other event",
    );
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && admin.session().epoch(&group).await.expect("epoch") == after_first + 1,
        "the removal was applied, or discarded, with no relay having answered for it",
    );
    for needle in ["was kept for its relays", "was given one"] {
        let line = lines
            .iter()
            .find(|line| line.message.contains(needle))
            .expect("what the open did to the stored fanouts is reported");
        assert_no_needles(
            std::slice::from_ref(line),
            &[
                &hex::encode(group.as_slice()),
                &admin.pubkey_hex(),
                &stale_event.to_hex(),
                &removal.to_hex(),
                "fanout-canary7f3a",
            ],
        );
    }

    // The removal confirms on an acknowledgement of ITS event, and only then.
    assert_eq!(
        drive_one(&admin.circle, &transport, &clock(), &own, &DriveMode::Full)
            .await
            .expect("the drive runs")
            .status,
        FanoutStatus::Confirmed
    );
    assert!(transport
        .calls()
        .iter()
        .all(|call| call.event_id == removal));
    assert_eq!(settled_member_count(&admin, &group).await, Some(2));
}

/// A pending row whose commit some other path APPLIED on this device is not
/// thrown away: the relays it was frozen for are still owed the commit, and
/// until one takes it this device is alone at the new epoch. The row is kept,
/// confirmed, and driven like any applied commit's.
#[tokio::test]
async fn a_pending_row_whose_commit_another_path_applied_still_owes_its_relays() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let pending = staged_ref(fx.admin(), &fx.group).await.expect("staged");
    fx.admin()
        .session()
        .confirm_published_past_its_fanout_for_test(pending)
        .await
        .expect("the bypass applies the commit");
    assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::Pending);

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
    let sent = transport.calls();
    assert_eq!(
        sent.len(),
        2,
        "a commit this device applied was not sent to the relays it was frozen for",
    );
    assert!(sent
        .iter()
        .all(|call| call.event_id == frozen.event_id && call.payload == frozen.payload));
    let kept = row(fx.admin(), &id).await;
    assert_eq!(kept.mls, FanoutMls::Confirmed);
    assert_eq!(
        kept.statuses,
        [
            FanoutTargetStatus::Accepted,
            FanoutTargetStatus::PossiblyExposed
        ],
    );
    assert_eq!(
        settled_member_count(fx.admin(), &fx.group).await,
        Some(1),
        "the applied commit stays applied",
    );
    // The second relay takes it on a later drive, and the record ends.
    transport.answer(TWO, [Answer::Accepted]);
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);
    assert!(probe(fx.admin(), &id).await.is_none());
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Gone);
}

/// A confirm that fails is not a publish failure. The error is returned, the
/// commit is not rolled back, the row keeps its acknowledgement, and the next
/// drive confirms it without writing to any relay.
#[tokio::test]
async fn a_failed_confirm_is_never_a_rollback_and_the_next_drive_confirms_it() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(admin.dir.path()).database_path();
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);

    // The confirm's own transaction marks the commit's row; that write fails.
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let failed = drive_one(&admin.circle, &transport, &clock(), &id, &DriveMode::Full).await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");

    assert!(failed.is_err(), "premise: the fault failed the confirm");
    assert!(
        staged_ref(admin, &fx.group).await.is_some(),
        "a failed confirm discarded an acknowledged commit",
    );
    let stored = row(admin, &id).await;
    assert_eq!(stored.mls, FanoutMls::Pending);
    assert!(
        stored.statuses.contains(&FanoutTargetStatus::Accepted),
        "the acknowledgement was stored before the confirm was tried",
    );

    // The acknowledgement is already stored, so the confirm needs no relay:
    // it must not wait for the one that never answered.
    let _ = transport.calls();
    transport.park();
    let clock = clock();
    let confirmed = tokio::select! {
        biased;
        outcome = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full) => Some(outcome),
        () = transport.parked() => None,
    };
    assert_eq!(
        confirmed
            .expect("the confirm waited on a relay although one had acknowledged")
            .expect("the drive runs")
            .status,
        FanoutStatus::Confirmed
    );
    assert_eq!(transport.calls().len(), 0);
    assert_eq!(settled_member_count(admin, &fx.group).await, Some(1));
}

// ── Rollback ─────────────────────────────────────────────────────────────────

/// When the rolled-back commit's own row cannot be retired, the rewind stands,
/// the fanout row stays as the marker, and the next drive finishes the job.
#[tokio::test]
async fn a_rollback_whose_retirement_failed_is_finished_by_the_next_drive() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let frozen = row(admin, &id).await;
    let key = StorageConfig::test_sqlcipher_key().expect("test key");
    let db = StorageConfig::new(admin.dir.path()).database_path();
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);

    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let mut status = None;
    let lines = capture_haven_log(async {
        status = Some(drive(&fx, &transport, &id).await);
    })
    .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");

    assert_eq!(status, Some(FanoutStatus::RolledBack));
    assert!(
        staged_ref(admin, &fx.group).await.is_none(),
        "the rewind stands"
    );
    assert_eq!(
        row(admin, &id).await.mls,
        FanoutMls::RolledBack,
        "the row is the marker that the commit's own row is still to retire",
    );
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Sent)
    );
    let line = lines
        .iter()
        .find(|line| line.message.contains("was not retired"))
        .expect("a retirement that failed is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(fx.group.as_slice()),
            &frozen.event_id.to_hex(),
            "fanout-canary7f3a",
        ],
    );

    let _ = transport.calls();
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::RolledBack);
    assert_eq!(
        transport.calls().len(),
        0,
        "finishing a rollback sends nothing"
    );
    assert!(probe(admin, &id).await.is_none());
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Failed)
    );
}

/// The eviction of a member who left, refused by every relay: rolled back
/// through the engine, which re-arms it; staged again it gets a new row, and
/// an acknowledgement then removes the leaver.
#[tokio::test]
async fn a_proven_rejection_everywhere_rolls_back_and_re_arms_the_self_remove() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, leaver) = (fx.admin(), &fx.members[2]);
    let session = admin.session();

    let leave = leaver
        .session()
        .leave_group(&fx.group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let proposal = SessionManager::proposal_events(&leave.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    assert!(matches!(
        session.process_event(&proposal).await.expect("ingest"),
        ScreenedIngest::Ingested(_)
    ));

    // Serves the deadlines the engine announces until the eviction is staged.
    let stage_eviction = || async {
        for _ in 0..8 {
            let staged = session
                .advance_for_drive(&fx.group, STAGED_AT)
                .await
                .expect("the advance runs");
            assert!(
                !staged
                    .effects
                    .publish
                    .iter()
                    .any(|work| matches!(work, PublishWork::AutoPublish { .. })),
                "a staging-mode advance handed the eviction back as publish work",
            );
            if let Some(id) = staged.fanouts.into_iter().next() {
                return id;
            }
            let wait = session
                .eviction_due_after_for_test(&fx.group)
                .await
                .or(session.receive_retick_after(&fx.group).await)
                .expect("the engine still owes the eviction a deadline");
            tokio::time::sleep(wait).await;
        }
        panic!("the eviction was never staged");
    };

    let first = stage_eviction().await;
    let frozen = row(admin, &first).await;
    assert!(
        !session.staged_without_fanout_for_test(&fx.group).await,
        "the eviction was staged with no row",
    );
    let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    assert_eq!(
        drive(&fx, &refusing, &first).await,
        FanoutStatus::RolledBack
    );
    assert!(staged_ref(admin, &fx.group).await.is_none());
    assert_eq!(settled_member_count(admin, &fx.group).await, Some(3));
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Failed),
        "the rolled-back commit's own row is retired",
    );

    let second = stage_eviction().await;
    assert!(
        row(admin, &second).await.event_id != frozen.event_id,
        "the re-armed eviction is a new commit with a row of its own",
    );
    let accepting = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Refused])]);
    assert_eq!(
        drive(&fx, &accepting, &second).await,
        FanoutStatus::Confirmed
    );
    assert_eq!(settled_member_count(admin, &fx.group).await, Some(2));
}

// ── W9b tail: one row per commit, bound by its origin ────────────────────────

fn commit_event_id(effects: &haven_core::nostr::mls::types::SessionEffects) -> nostr::EventId {
    effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { msg, .. } | PublishWork::AutoPublish { msg, .. } => {
                nostr::EventId::from_slice(msg.id.as_slice()).ok()
            }
            _ => None,
        })
        .expect("the call staged a commit")
}

fn db_of(member: &CircleMember) -> (std::path::PathBuf, storage_sqlite::SqlCipherKey) {
    (
        StorageConfig::new(member.dir.path()).database_path(),
        StorageConfig::test_sqlcipher_key().expect("test key"),
    )
}

/// Serves every deadline the engine announces for `group`, as a receive plane
/// would, so anything a convergence pass can select is selected.
async fn serve_deadlines(member: &CircleMember, group: &GroupId) {
    for _ in 0..4 {
        let Some(after) = member.session().receive_retick_after(group).await else {
            break;
        };
        tokio::time::sleep(after).await;
        let _ = member.session().advance_convergence(group).await;
    }
    let _ = member.session().advance_convergence(group).await;
}

/// A location `sender` seals for `group`.
async fn location_from(sender: &CircleMember, group: &GroupId) -> nostr::Event {
    sender
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await
        .expect("the sender encrypts")
        .0
}

/// A second circle of `member`'s own, alone in it, on `relays`.
async fn solo_circle(member: &CircleMember, relays: &[&str]) -> GroupId {
    let relays: Vec<String> = relays.iter().map(ToString::to_string).collect();
    member
        .circle
        .create_circle(
            &member.keys,
            Vec::new(),
            &haven_core::circle::CircleConfig::new("Solo").with_relays(relays.clone()),
        )
        .await
        .expect("the circle is created")
        .circle
        .mls_group_id
}

/// A stale row never outlives the next commit staged in its circle, so the
/// two can never sit side by side for a hydrate to mix up: the commit gets
/// its own row, is restored under it after a kill, and is never rolled back.
#[tokio::test]
async fn a_stale_row_never_costs_the_commit_staged_after_it() {
    for exposed in [Answer::Silent, Answer::Unreachable] {
        let fx = setup_circle(3, &[ONE, TWO]).await;
        let group = fx.group.clone();
        let stale = the_one_fanout(
            fx.admin()
                .session()
                .update_relays_staging(
                    &group,
                    vec![ONE.to_string(), TWO.to_string(), THREE.to_string()],
                    STAGED_AT,
                )
                .await
                .expect("a relay change is staged"),
        );
        let first = staged_ref(fx.admin(), &group).await.expect("staged");
        fx.admin()
            .session()
            .confirm_published_past_its_fanout_for_test(first)
            .await
            .expect("the bypass applies the first commit");
        assert_eq!(row(fx.admin(), &stale).await.mls, FanoutMls::Pending);

        let live = stage_removal(&fx).await;
        assert_eq!(
            row(fx.admin(), &stale).await.mls,
            FanoutMls::Confirmed,
            "a stale row was left pending beside the row of the commit staged after it",
        );
        let transport = answering(&[(ONE, &[exposed]), (TWO, &[exposed]), (THREE, &[exposed])]);
        assert_eq!(
            drive(&fx, &transport, &live).await,
            FanoutStatus::Unresolved
        );
        let frozen = row(fx.admin(), &live).await;

        let mut members = fx.members;
        let admin = members.remove(0).reopen();
        assert!(
            staged_ref(&admin, &group).await.is_some(),
            "the live commit was not restored after the kill",
        );
        assert_eq!(
            commit_row_state(&admin, &frozen).await,
            Some(MessageState::Sent),
            "a commit a relay may hold was retired",
        );
        let accepting = answering(&[(ONE, &[Answer::Accepted])]);
        let outcome = drive_one(&admin.circle, &accepting, &later(), &live, &DriveMode::Full)
            .await
            .expect("the drive runs");
        assert_eq!(outcome.status, FanoutStatus::Confirmed);
        assert!(
            accepting
                .calls()
                .iter()
                .all(|call| call.event_id == frozen.event_id && call.payload == frozen.payload),
            "what was sent after the restart is not the frozen event",
        );
        assert_eq!(settled_member_count(&admin, &group).await, Some(2));
    }
}

/// A row with nothing staged behind it and nothing ever sent under it is a
/// preparation nobody saw. It is abandoned: its commit's own row retired, so
/// no convergence pass merges a commit no relay was sent, and the row removed.
#[tokio::test]
async fn a_pending_row_with_nothing_staged_behind_it_and_nothing_sent_is_abandoned() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let before = admin.session().epoch(&fx.group).await.expect("epoch");
    let id = stage_removal(&fx).await;
    let frozen = row(admin, &id).await;
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    let (db, key) = db_of(admin);

    // The engine call rewinds the commit; its row cannot be retired.
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        staged_ref(admin, &fx.group).await.is_none(),
        "premise: rewound"
    );
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Sent),
        "premise: the rewound commit's row is still stored as sent",
    );

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let mut status = None;
    let lines = capture_haven_log(async {
        status = Some(drive(&fx, &transport, &id).await);
    })
    .await;
    assert_eq!(status, Some(FanoutStatus::Stale));
    assert_eq!(
        transport.calls().len(),
        0,
        "a commit the engine rewound was published",
    );
    assert!(probe(admin, &id).await.is_none(), "the row was kept");
    assert!(!is_owned(&frozen.event_id));
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Failed),
        "the abandoned commit can still be selected by a convergence pass",
    );
    let line = lines
        .iter()
        .find(|line| {
            line.message
                .contains("nothing staged behind it and nothing sent")
        })
        .expect("abandoning a record is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(fx.group.as_slice()),
            &frozen.event_id.to_hex(),
            "fanout-canary7f3a",
        ],
    );
    serve_deadlines(admin, &fx.group).await;
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before,
        "a commit no relay was ever sent was merged",
    );
    // The circle takes the same change again at once.
    let again = stage_removal(&fx).await;
    assert_eq!(
        drive(&fx, &transport, &again).await,
        FanoutStatus::Confirmed
    );
}

/// A row an attempt was begun under, whose commit the engine no longer holds:
/// a relay may hold a commit this device can neither confirm nor discard. The
/// row is kept, nothing is sent under it again, and the circle takes no new
/// change beside it — in this session, across a restart, and whatever number
/// the next commit's pending ref carries.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_pending_row_a_relay_may_hold_that_is_no_longer_staged_blocks_new_changes() {
    use haven_core::nostr::mls::types::SendIntent;
    use haven_core::nostr::NostrError;

    let fx = setup_circle(3, &[ONE, TWO]).await;
    let group = fx.group.clone();
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let silent = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
    assert_eq!(drive(&fx, &silent, &id).await, FanoutStatus::Unresolved);
    let pending = staged_ref(fx.admin(), &group).await.expect("staged");
    let (db, key) = db_of(fx.admin());
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = fx
        .admin()
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert!(staged_ref(fx.admin(), &group).await.is_none(), "premise");

    // Every relay would acknowledge it: nothing is sent, nothing is removed.
    let accepting = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    assert_eq!(drive(&fx, &accepting, &id).await, FanoutStatus::Unresolved);
    assert_eq!(accepting.calls().len(), 0);
    assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::Pending);

    // No new change is staged beside it: the legacy call is refused before
    // the engine is asked, and a staging-mode one is undone in its own hold.
    let other = [fx.members[1].pubkey_hex()];
    assert!(matches!(
        fx.admin().session().remove_members(&group, &other).await,
        Err(NostrError::EpochNotStable)
    ));
    let mut staged = None;
    let lines = capture_haven_log(async {
        staged = Some(
            fx.admin()
                .session()
                .remove_members_staging(&group, &other, STAGED_AT)
                .await
                .expect("a change that cannot be recorded is undone, not an error"),
        );
    })
    .await;
    assert!(staged.expect("ran").fanouts.is_empty());
    assert!(staged_ref(fx.admin(), &group).await.is_none());
    assert!(lines.iter().any(|line| line
        .message
        .contains("could not be recorded and is rolled back")));

    // Across a restart the row is kept and bound to nothing.
    let mut members = fx.members;
    let mut reopened = None;
    let admin = members.remove(0);
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");
    assert_eq!(row(&admin, &id).await.mls, FanoutMls::Pending);
    assert!(staged_ref(&admin, &group).await.is_none());
    let line = lines
        .iter()
        .find(|line| {
            line.message
                .contains("a relay may hold is no longer staged")
        })
        .expect("the open reports a record it can no longer resolve");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &frozen.event_id.to_hex(),
            "fanout-canary7f3a",
        ],
    );

    // A commit staged past the refusal, in this circle and in another, takes
    // the number the old row carries: a new session counts from one again.
    let elsewhere = solo_circle(&admin, &[ONE]).await;
    let rename = |group_id: &GroupId| SendIntent::UpdateGroupData {
        group_id: group_id.clone(),
        name: Some("renamed".to_string()),
        description: None,
    };
    let foreign = admin
        .session()
        .send(rename(&elsewhere))
        .await
        .expect("another circle is not blocked");
    let foreign_ref = staged_ref(&admin, &elsewhere).await.expect("staged");
    assert!(
        !matches!(
            admin.circle.session().publish_failed(foreign_ref).await,
            Err(haven_core::nostr::NostrError::FanoutOwned)
        ),
        "a legacy commit in another circle was refused over a number an old \
         row of this circle carries",
    );
    drop(foreign);
    // …and in a session of its own the next change of THIS circle is the
    // first commit staged, as the old row's was in its session.
    let admin = admin.reopen();
    admin
        .session()
        .send_past_a_pending_fanout_for_test(rename(&group))
        .await
        .expect("the bypass stages a change beside the old row");
    let twin = staged_ref(&admin, &group).await.expect("staged");
    let epoch = admin.session().epoch(&group).await.expect("epoch");

    let status = drive_one(&admin.circle, &accepting, &later(), &id, &DriveMode::Full)
        .await
        .expect("the drive runs")
        .status;
    assert_eq!(status, FanoutStatus::Unresolved);
    assert_eq!(
        accepting.calls().len(),
        0,
        "the old row's event was sent while a different commit was staged",
    );
    assert_eq!(
        staged_ref(&admin, &group).await,
        Some(twin),
        "a commit no relay was sent was confirmed or discarded through \
         another commit's row",
    );
    assert_eq!(admin.session().epoch(&group).await.expect("epoch"), epoch);

    // A kill with both in place: the old row is not the staged commit's, so
    // it is gone before the engine can bind it.
    let admin = admin.reopen();
    assert!(
        probe(&admin, &id).await.is_none(),
        "a row that no longer describes the staged commit survived the open",
    );
    let status = drive_one(&admin.circle, &accepting, &later(), &id, &DriveMode::Full)
        .await
        .expect("the drive runs")
        .status;
    assert_eq!(status, FanoutStatus::Gone);
    assert_eq!(accepting.calls().len(), 0);
}

// ── W9b tail: the row decides, never the engine call's result ────────────────

/// The engine's rollback stores the rewind and can still fail afterwards, in
/// the replay of what was buffered while the commit was staged. The commit's
/// own row is retired all the same: left as sent, the next convergence pass
/// would merge a commit every relay refused.
#[tokio::test]
async fn a_rollback_that_fails_after_the_rewind_still_retires_the_commit() {
    use haven_core::nostr::mls::storage::set_stored_message_write_fault_sparing_for_test;

    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let before = admin.session().epoch(&fx.group).await.expect("epoch");
    let id = stage_removal(&fx).await;
    let frozen = row(admin, &id).await;
    // A peer's location arrives while the commit is staged: buffered.
    let buffered = location_from(&fx.members[1], &fx.group).await;
    let _ = admin.circle.ingest_for_test(&buffered).await;
    let (db, key) = db_of(admin);
    let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);

    // Re-stating the replayed row fails; the commit's own row can be written.
    set_stored_message_write_fault_sparing_for_test(&db, &key, frozen.event_id.as_bytes(), true)
        .expect("arm");
    let failed = drive_one(&admin.circle, &refusing, &clock(), &id, &DriveMode::Full).await;
    set_stored_message_write_fault_sparing_for_test(&db, &key, frozen.event_id.as_bytes(), false)
        .expect("disarm");

    // Undone beside an error is undone: the stored record says so, and the
    // drive reports it with the error, not instead of it.
    let failed = failed.unwrap_or_else(|_| panic!("a completed rewind was reported as an error"));
    assert!(
        failed.error.is_some(),
        "premise: the rollback failed in the engine's own tail"
    );
    assert_eq!(failed.status, FanoutStatus::RolledBack);
    assert!(
        staged_ref(admin, &fx.group).await.is_none(),
        "premise: the rewind itself had completed",
    );
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Failed),
        "a rewound commit was left stored as sent because the engine call \
         that rewound it returned an error",
    );
    assert!(
        probe(admin, &id).await.is_none(),
        "the finished row was kept"
    );
    serve_deadlines(admin, &fx.group).await;
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before,
        "a commit every relay refused was merged by a later convergence pass",
    );
    assert_eq!(settled_member_count(admin, &fx.group).await, Some(3));
}

/// A call that makes no commit — an inputs-only advance, a send's departure
/// check — never hands on a commit the engine staged beside a pending row a
/// relay may hold: it is undone in the hold that staged it. No receive plane
/// can be made to stage one on cue (the engine's own convergence disposes of
/// the older commit first), so the check is handed a commit staged past the
/// send's refusal.
#[tokio::test]
async fn a_call_that_makes_no_commit_hands_on_none_staged_beside_a_pending_row_a_relay_may_hold() {
    use haven_core::nostr::mls::types::SendIntent;

    let fx = setup_circle(2, &[ONE]).await;
    let admin = fx.admin();
    let session = admin.session();
    let id = the_one_fanout(
        session
            .update_relays_staging(&fx.group, vec![TWO.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged"),
    );
    let silent = answering(&[(ONE, &[Answer::Silent])]);
    assert_eq!(drive(&fx, &silent, &id).await, FanoutStatus::Unresolved);
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    let (db, key) = db_of(admin);
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = session
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert_eq!(row(admin, &id).await.mls, FanoutMls::Pending, "premise");

    let beside = session
        .send_past_a_pending_fanout_for_test(SendIntent::UpdateGroupData {
            group_id: fx.group.clone(),
            name: Some("renamed".to_string()),
            description: None,
        })
        .await
        .expect("the bypass stages a change beside the old row");
    let commit = commit_event_id(&beside);
    assert!(staged_ref(admin, &fx.group).await.is_some(), "premise");

    let mut handed_on = None;
    let lines = capture_haven_log(async {
        handed_on = Some(session.unstaged_beside_a_fanout_for_test(beside).await);
    })
    .await;
    let handed_on = handed_on.expect("ran");
    assert!(
        !handed_on.publish.iter().any(|work| matches!(
            work,
            PublishWork::AutoPublish { .. } | PublishWork::GroupEvolution { .. }
        )),
        "a commit staged beside a pending row a relay may hold was handed to \
         a legacy publisher",
    );
    assert!(staged_ref(admin, &fx.group).await.is_none());
    let line = lines
        .iter()
        .find(|line| {
            line.message
                .contains("staged beside an unresolved pending one")
        })
        .expect("undoing the commit is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(fx.group.as_slice()),
            &admin.pubkey_hex(),
            &commit.to_hex(),
            "fanout-canary7f3a",
        ],
    );
    assert_eq!(row(admin, &id).await.mls, FanoutMls::Pending);
}

/// When the rolled-back commit's own row cannot be retired, nothing advances
/// its circle before a drive has finished the job: the fold that follows the
/// rollback would otherwise run the convergence pass that merges it.
#[tokio::test]
async fn nothing_advances_a_circle_whose_rolled_back_commit_is_not_yet_retired() {
    use haven_core::nostr::mls::storage::set_commit_retirement_fault_for_test;

    let fx = setup_circle(2, &[ONE, TWO]).await;
    let admin = fx.admin();
    let before = admin.session().epoch(&fx.group).await.expect("epoch");
    let id = the_one_fanout(
        admin
            .session()
            .update_relays_staging(&fx.group, vec![THREE.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged"),
    );
    let frozen = row(admin, &id).await;
    // What the rollback replays makes the fold owe this circle an advance.
    let buffered = location_from(&fx.members[1], &fx.group).await;
    let _ = admin.circle.ingest_for_test(&buffered).await;
    let (db, key) = db_of(admin);
    let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);

    set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), true).expect("arm");
    let status = drive(&fx, &refusing, &id).await;
    set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), false)
        .expect("disarm");

    assert_eq!(status, FanoutStatus::RolledBack);
    assert_eq!(
        row(admin, &id).await.mls,
        FanoutMls::RolledBack,
        "premise: the retirement failed and the row stayed as its marker",
    );
    assert_eq!(
        commit_row_state(admin, &frozen).await,
        Some(MessageState::Sent),
        "the rolled-back commit was merged before its row could be retired",
    );
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before
    );
    // The next drive finishes it, and only then may the circle advance.
    assert_eq!(drive(&fx, &refusing, &id).await, FanoutStatus::RolledBack);
    serve_deadlines(admin, &fx.group).await;
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before
    );
}

/// A commit the engine staged in some other call gets its row the moment the
/// staging step is handed it, under the lock — and when it can be neither
/// recorded nor rolled back it is handed back with its live ref, never
/// dropped, and the next open gives the removal its record.
#[tokio::test]
async fn a_commit_handed_to_the_staging_step_is_recorded_or_handed_back_never_dropped() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let group = fx.group.clone();
    let last = [fx.members[2].pubkey_hex()];

    // Recorded.
    let effects = fx
        .admin()
        .session()
        .remove_members(&group, &last)
        .await
        .expect("a removal is staged the legacy way");
    let commit = commit_event_id(&effects);
    let staged = fx
        .admin()
        .session()
        .stage_commits_for_test(effects, STAGED_AT)
        .await;
    let id = the_one_fanout(staged);
    assert_eq!(row(fx.admin(), &id).await.event_id, commit);
    assert!(
        !fx.admin()
            .session()
            .staged_without_fanout_for_test(&group)
            .await
    );
    let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    assert_eq!(drive(&fx, &refusing, &id).await, FanoutStatus::RolledBack);

    // Neither recorded nor rolled back.
    let effects = fx
        .admin()
        .session()
        .remove_members(&group, &last)
        .await
        .expect("the removal is staged again");
    let commit = commit_event_id(&effects);
    let (db, key) = db_of(fx.admin());
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::OwnCommitIntentDelete, true)
        .expect("arm");
    let mut staged = None;
    let lines = capture_haven_log(async {
        staged = Some(
            fx.admin()
                .session()
                .stage_commits_for_test(effects, STAGED_AT)
                .await,
        );
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::OwnCommitIntentDelete, false)
        .expect("disarm");
    let staged = staged.expect("ran");
    assert!(staged.fanouts.is_empty());
    assert_eq!(
        commit_event_id(&staged.effects),
        commit,
        "a commit that could be neither recorded nor rolled back was dropped \
         from the batch",
    );
    assert!(staged_ref(fx.admin(), &group).await.is_some());
    let line = lines
        .iter()
        .find(|line| line.message.contains("neither recorded nor rolled back"))
        .expect("the hand-back is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &commit.to_hex(),
            "fanout-canary7f3a",
        ],
    );

    // A kill then: the open finds the removal staged with no record.
    let mut members = fx.members;
    let admin = members.remove(0).reopen();
    let ids = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("ids");
    let [repaired] = <[FanoutId; 1]>::try_from(ids).unwrap_or_else(|_| panic!("one row"));
    assert_eq!(row(&admin, &repaired).await.event_id, commit);
    let accepting = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let status = drive_one(
        &admin.circle,
        &accepting,
        &later(),
        &repaired,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs")
    .status;
    assert_eq!(status, FanoutStatus::Confirmed);
    assert_eq!(settled_member_count(&admin, &group).await, Some(2));
}

/// A circle with no relay this device may dial cannot publish a commit at
/// all. The commit is undone in the hold that staged it: it never sits
/// pending — holding the circle's sends and its unread traffic — for a drive
/// that could only roll it back.
#[tokio::test]
async fn a_commit_with_no_relay_to_go_to_is_undone_in_the_hold_that_staged_it() {
    use cgka_traits::app_components::{
        encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
    };
    use haven_core::nostr::mls::types::{AppComponentData, SendIntent};

    let fx = setup_circle(3, &[ONE]).await;
    let session = fx.admin().session();
    // Written straight to the engine, as another client's admin would.
    let (nostr_group_id, _) = session.group_routing(&fx.group).await.expect("routing");
    let routing = NostrRoutingV1::new(
        nostr_group_id,
        vec!["ws://refused-entry.invalid".to_string()],
    )
    .expect("MDK admits ws");
    let foreign = session
        .send(SendIntent::UpdateAppComponents {
            group_id: fx.group.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(&routing).expect("the component encodes"),
            }],
        })
        .await
        .expect("the routing change is staged");
    drop(foreign);
    let pending = staged_ref(fx.admin(), &fx.group).await.expect("staged");
    session.confirm_published(pending).await.expect("applied");

    let staged = session
        .remove_members_staging(&fx.group, &[fx.members[2].pubkey_hex()], STAGED_AT)
        .await
        .expect("a commit with nowhere to go is undone, not an error");
    assert!(
        staged.fanouts.is_empty(),
        "a row frozen for no relay was written"
    );
    assert!(
        staged_ref(fx.admin(), &fx.group).await.is_none(),
        "a commit no relay can be sent was left pending",
    );
    assert_eq!(settled_member_count(fx.admin(), &fx.group).await, Some(3));
}

// ── W9b tail: what the driver's commit is to everyone else ───────────────────

/// What the driver sent is a commit a peer applies, and it carries the one
/// tag a group message may: `h`.
#[tokio::test]
async fn a_peer_applies_the_frozen_event_a_confirmed_drive_sent() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    assert_eq!(drive(&fx, &transport, &id).await, FanoutStatus::Confirmed);

    let sent = transport.calls();
    let event = nostr::Event::from_json(&sent[0].payload).expect("the frozen event");
    assert!(event.verify().is_ok());
    let tags: Vec<&str> = event
        .tags
        .iter()
        .map(|tag| tag.as_slice()[0].as_str())
        .collect();
    assert_eq!(tags, ["h"], "a commit carries the routing tag and no other");

    let peer = &fx.members[1];
    peer.session()
        .process_event_settled_for_test(&event)
        .await
        .expect("the peer applies the commit");
    assert_eq!(
        peer.session().epoch(&fx.group).await.expect("epoch"),
        fx.admin().session().epoch(&fx.group).await.expect("epoch"),
    );
    assert_eq!(settled_member_count(peer, &fx.group).await, Some(2));
    // One branch: the peer reads what the committer seals at the new epoch.
    let from_admin = location_from(fx.admin(), &fx.group).await;
    assert!(
        !peer
            .circle
            .ingest_for_test(&from_admin)
            .await
            .expect("the peer decrypts")
            .is_empty(),
        "the peer applied a commit that left it on another branch",
    );
}

/// An invite through the driver: its Welcome stays in the commit's row and is
/// handed to nobody until the commit is applied. The confirm promotes the
/// engine's own copy to an outstanding delivery, and THAT copy — matched to
/// the row's by id — is what the drive hands over, once, beside the commit it
/// belongs to. The record outlives its last relay call for as long as the
/// Welcome is undelivered. A commit still unacknowledged releases nothing,
/// and a rolled-back one retires its Welcome for good (Security Rule 3).
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn an_invites_welcome_is_handed_over_by_its_commits_confirm_and_by_nothing_else() {
    for (answer, expected) in [
        (Answer::Accepted, FanoutStatus::Confirmed),
        (Answer::Silent, FanoutStatus::Unresolved),
        (Answer::Refused, FanoutStatus::RolledBack),
    ] {
        let fx = setup_circle(2, &[ONE]).await;
        let session = fx.admin().session();
        let joiner = CircleMember::new();
        let event =
            helpers::create_key_package_event(joiner.session(), &joiner.keys, &[ONE.to_string()])
                .await;
        let before = session
            .outstanding_welcome_ids_for_test()
            .await
            .expect("welcomes");
        let staged = fx
            .admin()
            .circle
            .add_members_staging(
                &fx.group,
                &[haven_core::circle::MemberKeyPackage {
                    key_package_event: event,
                    inbox_relays: vec![JOINER_INBOX.to_string()],
                    nip65_relays: Vec::new(),
                    nip65_write_relays: Vec::new(),
                }],
                STAGED_AT,
            )
            .await
            .expect("the invite is staged");
        let id = staged.commit.expect("the invite's one commit is recorded");
        let frozen = row(fx.admin(), &id).await;
        let [frozen_welcome] = <[MessageId; 1]>::try_from(frozen.welcome_ids.clone())
            .unwrap_or_else(|_| panic!("the row froze the invite's one Welcome"));
        assert_eq!(
            session
                .outstanding_welcome_ids_for_test()
                .await
                .expect("welcomes"),
            before,
            "a Welcome was deliverable before its commit was acknowledged",
        );

        let transport = answering(&[(ONE, &[answer])]);
        let outcome = drive_one(
            &fx.admin().circle,
            &transport,
            &later(),
            &id,
            &DriveMode::Full,
        )
        .await
        .expect("the drive runs");
        assert_eq!(outcome.status, expected);
        let sent = transport.calls();
        assert!(
            sent.iter()
                .all(|call| nostr::Event::from_json(&call.payload)
                    .is_ok_and(|event| event.kind == nostr::Kind::Custom(445))),
            "something other than the commit was sent",
        );
        let outstanding = session
            .outstanding_welcome_ids_for_test()
            .await
            .expect("welcomes");
        match expected {
            FanoutStatus::Confirmed => {
                // Handed over to a delivery record of its own — the Welcome
                // the row froze, beside its commit, owed to its invitee's
                // inbox — and the engine holds it for delivery.
                let record = session.welcome_record_for_test(&frozen_welcome).await;
                assert!(
                    record.as_ref().is_some_and(|(commit, relays, _)| {
                        commit.as_slice() == frozen.event_id.as_bytes().as_slice()
                            && relays == &[JOINER_INBOX.to_string()]
                    }) && !before.contains(&frozen_welcome)
                        && outstanding.contains(&frozen_welcome),
                    "the confirm did not hand the row's Welcome to a delivery record, or the \
                     engine does not hold it for delivery",
                );
                // The row has let go of it and, holding nothing more, ended:
                // a drive of the row alone writes to no relay.
                assert!(probe(fx.admin(), &id).await.is_none());
                let again = drive_one(
                    &fx.admin().circle,
                    &transport,
                    &later(),
                    &id,
                    &DriveMode::Full,
                )
                .await
                .expect("the drive runs");
                assert_eq!(again.status, FanoutStatus::Gone);
                assert_eq!(transport.calls().len(), 0, "a relay was written to again");
                assert!(session
                    .outstanding_welcome_ids_for_test()
                    .await
                    .expect("welcomes")
                    .contains(&frozen_welcome));
            }
            FanoutStatus::Unresolved => {
                assert!(
                    session
                        .welcome_record_for_test(&frozen_welcome)
                        .await
                        .is_none()
                        && outstanding == before,
                    "a Welcome was released for a commit no relay has acknowledged",
                );
                assert_eq!(row(fx.admin(), &id).await.held_welcomes, 1);
            }
            _ => {
                assert!(
                    session
                        .welcome_record_for_test(&frozen_welcome)
                        .await
                        .is_none()
                        && outstanding == before,
                    "a rolled-back invite released or left a deliverable Welcome",
                );
                assert!(probe(fx.admin(), &id).await.is_none());
            }
        }
    }
}

/// What arrived while the commit was staged is held unread, and is handed
/// back by whichever way the commit is resolved.
#[tokio::test]
async fn traffic_buffered_behind_a_pending_commit_is_delivered_by_either_resolution() {
    for (answer, expected) in [
        (Answer::Accepted, FanoutStatus::Confirmed),
        (Answer::Refused, FanoutStatus::RolledBack),
    ] {
        let fx = setup_circle(3, &[ONE]).await;
        let admin = fx.admin();
        let id = stage_removal(&fx).await;
        let buffered = location_from(&fx.members[1], &fx.group).await;
        assert!(
            admin
                .circle
                .ingest_for_test(&buffered)
                .await
                .expect("the ingest runs")
                .is_empty(),
            "premise: a location that arrives behind a pending commit is held",
        );

        let transport = answering(&[(ONE, &[answer])]);
        let outcome = drive_one(&admin.circle, &transport, &later(), &id, &DriveMode::Full)
            .await
            .expect("the drive runs");
        assert_eq!(outcome.status, expected);
        let locations = outcome
            .replayed
            .results
            .iter()
            .filter(|result| {
                matches!(
                    result,
                    haven_core::nostr::mls::types::LocationMessageResult::Location { .. }
                )
            })
            .count();
        assert_eq!(
            locations, 1,
            "the location held behind the commit was not handed back when the \
             commit was resolved",
        );
        assert!(outcome.staged.is_empty());
    }
}

/// The leaver's eviction a peer committed from `fx`'s current epoch, with the
/// leave proposal it commits.
async fn a_peers_eviction(fx: &CircleFixture) -> (nostr::Event, nostr::Event) {
    let (peer, leaver) = (&fx.members[1], &fx.members[2]);
    let leave = leaver
        .session()
        .leave_group(&fx.group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let proposal = SessionManager::proposal_events(&leave.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    let ingested = peer
        .session()
        .process_event(&proposal)
        .await
        .expect("ingest");
    let mut batches = match ingested {
        ScreenedIngest::Ingested(ingest) => vec![ingest.effects],
        ScreenedIngest::RejectedBeforeAuth(_) => panic!("rejected"),
    };
    for _ in 0..8 {
        if let Some((commit, pending)) =
            batches
                .iter()
                .flat_map(|batch| &batch.publish)
                .find_map(|work| match work {
                    PublishWork::AutoPublish { msg, pending } => Some((
                        SessionManager::transport_message_to_event(msg).expect("a commit"),
                        *pending,
                    )),
                    _ => None,
                })
        {
            peer.session()
                .confirm_published(pending)
                .await
                .expect("the peer confirms");
            return (proposal, commit);
        }
        let wait = peer
            .session()
            .receive_retick_after(&fx.group)
            .await
            .expect("the engine owes the eviction a deadline");
        tokio::time::sleep(wait).await;
        batches = vec![peer
            .session()
            .stage_unrecorded_for_test(&fx.group)
            .await
            .expect("advance")];
    }
    panic!("the peer never staged the eviction");
}

/// What the driver's seal answers for `member`'s circle now.
async fn driver_seal(member: &CircleMember, group: &GroupId) -> Result<nostr::Event, SendHeld> {
    let (transport, outbox, clock) = (
        ScriptedFanout::default(),
        helpers::drive::Recorder::acking(true),
        helpers::drive::ManualClock::at(0),
    );
    match helpers::drive::through(&transport, &outbox, &clock, &DriveMode::Full)
        .seal_location(
            &member.circle,
            group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await
        .expect("the seal runs")
        .seal
    {
        LocationSeal::Sealed { event, .. } => Ok(*event),
        LocationSeal::Deferred(held) => Err(held),
    }
}

/// A commit every relay refused is gone for good, and the circle goes on: a
/// peer's commit from the same epoch is applied over it.
#[tokio::test]
async fn a_peers_commit_from_the_same_epoch_applies_after_a_rollback() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, peer) = (fx.admin(), &fx.members[1]);
    let id = the_one_fanout(
        admin
            .session()
            .update_relays_staging(&fx.group, vec![TWO.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged"),
    );
    let refusing = answering(&[(ONE, &[Answer::Refused])]);
    assert_eq!(drive(&fx, &refusing, &id).await, FanoutStatus::RolledBack);

    // The other member evicts a leaver from the epoch the rollback returned to.
    let (proposal, commit) = a_peers_eviction(&fx).await;

    let _ = admin
        .session()
        .process_event_settled_for_test(&proposal)
        .await;
    admin
        .session()
        .process_event_settled_for_test(&commit)
        .await
        .expect("the peer's commit is ingested");
    serve_deadlines(admin, &fx.group).await;
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        peer.session().epoch(&fx.group).await.expect("epoch"),
    );
    assert_eq!(settled_member_count(admin, &fx.group).await, Some(2));
    let from_peer = location_from(peer, &fx.group).await;
    assert!(
        !admin
            .circle
            .ingest_for_test(&from_peer)
            .await
            .expect("decrypts")
            .is_empty(),
        "after a rollback the device did not follow the peer's commit",
    );
}

/// A peer's commit buffered behind this device's pending commit, and held
/// again by a later page that still reads it as current, is released by
/// either resolution: MDK replays it when the pending commit resolves, and
/// records it then, so the hold waits on no refetch.
#[tokio::test]
async fn a_commit_buffered_behind_a_pending_commit_and_held_again_is_released_by_either_resolution()
{
    for (answer, expected) in [
        (Answer::Refused, FanoutStatus::RolledBack),
        (Answer::Accepted, FanoutStatus::Confirmed),
    ] {
        let fx = setup_circle(3, &[ONE]).await;
        let (admin, peer, leaver) = (fx.admin(), &fx.members[1], &fx.members[2]);
        let (proposal, eviction) = a_peers_eviction(&fx).await;
        let id = the_one_fanout(
            admin
                .session()
                .update_relays_staging(&fx.group, vec![TWO.to_string()], STAGED_AT)
                .await
                .expect("a relay change is staged"),
        );
        for event in [&proposal, &eviction] {
            let _ = admin
                .session()
                .process_event(event)
                .await
                .expect("the admin's engine takes the event");
        }
        admin
            .session()
            .hold_pager_commits_for_test(&fx.group, &[eviction.id]);
        assert!(
            !admin.session().engine_processed(&eviction.id)
                && admin.session().holds_unread_input_for_test(&fx.group),
            "premise: the peer's commit is held, buffered raw behind the pending commit"
        );

        let resolved = drive(&fx, &answering(&[(ONE, &[answer])]), &id).await;
        assert_eq!(resolved, expected);
        assert!(
            admin.session().engine_processed(&eviction.id),
            "premise: MDK's replay at the resolution ({resolved:?}) recorded the commit"
        );
        assert!(
            !admin.session().holds_unread_input_for_test(&fx.group),
            "the hold outlived the replay that took the commit in ({resolved:?})"
        );
        serve_deadlines(admin, &fx.group).await;
        let sealed = match driver_seal(admin, &fx.group).await {
            Err(SendHeld::Nothing) => driver_seal(admin, &fx.group).await,
            first => first,
        }
        .unwrap_or_else(|held| panic!("the seal is held after {resolved:?}: {held:?}"));
        if answer == Answer::Refused {
            // The peer's eviction is the only commit from the epoch.
            assert_eq!(settled_member_count(admin, &fx.group).await, Some(2));
            assert!(
                !helpers::drive::reads(leaver, &sealed).await
                    && helpers::drive::reads(peer, &sealed).await,
                "after the rollback the seal is not on the peer's eviction"
            );
        } else {
            // The admin's relay change is a privileged commit, which outranks
            // the peer's eviction from the same epoch in MDK's branch
            // selection: the leaver is still listed, its leave superseded.
            assert_eq!(settled_member_count(admin, &fx.group).await, Some(3));
        }
    }
}

// ── The real classifier under the driver ─────────────────────────────────────

/// A relay client whose every publish fails as a whole, naming no relay.
struct NamesNoRelay;

#[async_trait::async_trait]
impl transport_nostr_adapter::NostrRelayClient for NamesNoRelay {
    async fn subscribe(
        &self,
        _: transport_nostr_adapter::NostrSubscription,
    ) -> Result<(), cgka_traits::TransportAdapterError> {
        Err(cgka_traits::TransportAdapterError::Closed)
    }

    async fn unsubscribe(
        &self,
        _: transport_nostr_adapter::NostrSubscription,
    ) -> Result<(), cgka_traits::TransportAdapterError> {
        Err(cgka_traits::TransportAdapterError::Closed)
    }

    async fn unsubscribe_account(
        &self,
        _: &cgka_traits::MemberId,
    ) -> Result<(), cgka_traits::TransportAdapterError> {
        Err(cgka_traits::TransportAdapterError::Closed)
    }

    async fn publish_event(
        &self,
        _: &[cgka_traits::TransportEndpoint],
        _: &transport_nostr_peeler::NostrTransportEvent,
        _: usize,
    ) -> Result<transport_nostr_adapter::NostrPublishOutcome, cgka_traits::TransportAdapterError>
    {
        Err(cgka_traits::TransportAdapterError::Publish(
            "publish failed before any relay was named".to_string(),
        ))
    }
}

/// An answer from MDK's relay client that classifies no relay proves nothing:
/// the driver stores each target possibly exposed, and no later refusal
/// undoes that. Through the real transport and its classifier; the relay
/// client is scripted, so the two relays are registered and never dialled.
#[tokio::test]
async fn an_outcome_with_no_per_target_classification_is_possibly_exposed() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let relays = RelayManager::new();
    let unclassified = relays.fanout_transport_over_for_test(std::sync::Arc::new(NamesNoRelay));

    let status = drive_one(
        &fx.admin().circle,
        &unclassified,
        &clock(),
        &id,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs")
    .status;
    assert_eq!(status, FanoutStatus::Unresolved);
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [FanoutTargetStatus::PossiblyExposed; 2],
        "an answer that named no relay was stored as something a rollback may act on",
    );

    let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    assert_eq!(drive(&fx, &refusing, &id).await, FanoutStatus::Unresolved);
    assert!(staged_ref(fx.admin(), &fx.group).await.is_some());
}

// ── Targets ──────────────────────────────────────────────────────────────────

/// A peer's relay change that this device has received and not yet applied is
/// folded by the send that stages the next commit. That commit leaves the
/// epoch AFTER the change, so it is frozen for the relays the change named —
/// which a reading taken before the engine call would have missed.
///
/// Waits out one convergence window the engine announces, without advancing.
#[tokio::test]
async fn a_commit_staged_after_a_folded_peer_routing_change_targets_its_source_epoch_relays() {
    let g = helpers::setup_two_party_group("fanout_folded_routing").await;
    let confirm = |effects: haven_core::nostr::mls::types::SessionEffects| {
        let (msg, pending) = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("one commit");
        let alice = &g.alice;
        async move {
            alice.confirm_published(pending).await.expect("confirm");
            SessionManager::transport_message_to_event(&msg).expect("a commit event")
        }
    };

    // Bob becomes an admin, so he can commit at all.
    let promotion = confirm(
        g.alice
            .update_admin_policy(
                &g.group_id,
                &[
                    g.alice_keys.public_key().to_bytes(),
                    g.bob_keys.public_key().to_bytes(),
                ],
            )
            .await
            .expect("alice promotes bob"),
    )
    .await;
    g.bob
        .process_event_settled_for_test(&promotion)
        .await
        .expect("bob applies the promotion");
    let before = g.bob.group_relays(&g.group_id).await.expect("relays");

    // Alice moves the circle; Bob has the commit and has not applied it.
    let moved = confirm(
        g.alice
            .update_relays(&g.group_id, vec![ONE.to_string()])
            .await
            .expect("alice moves the circle"),
    )
    .await;
    assert!(matches!(
        g.bob.process_event(&moved).await.expect("ingest"),
        ScreenedIngest::Ingested(_)
    ));
    let window = g
        .bob
        .receive_retick_after(&g.group_id)
        .await
        .expect("the engine announces when the change can be applied");
    tokio::time::sleep(window).await;
    assert_eq!(
        g.bob.group_relays(&g.group_id).await.expect("relays"),
        before,
        "premise: the peer's change is still unapplied when the send begins",
    );

    let staged = g
        .bob
        .update_relays_staging(&g.group_id, vec![TWO.to_string()], STAGED_AT)
        .await
        .expect("bob stages his own change");
    let id = the_one_fanout(staged);
    let frozen = g
        .bob
        .fanout_probe_for_test(&id)
        .await
        .expect("the store is read")
        .expect("the row exists");
    assert_eq!(
        frozen.targets,
        [ONE],
        "the commit was frozen for relays its source epoch no longer names",
    );
    g.cleanup();
}
