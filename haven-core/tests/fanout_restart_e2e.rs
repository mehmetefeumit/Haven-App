//! The durable fanout driver across a restart, and its pacing (Security
//! Rule 13).
//!
//! A commit staged with its fanout row survives the process that staged it:
//! MDK's hydrate restores the pending commit from the row, and the driver
//! sends the row's frozen event again — never a commit staged a second time —
//! with one drive of a row at a time. What an earlier process left half done
//! is settled before the engine opens: a rollback is finished, a row that no
//! longer describes the staged commit is removed, and a removal a kill left
//! staged with no row is given one.
//!
//! Real MDK engines over `SQLCipher` stores. "A kill" is the manager dropped
//! and the same stores opened again: nothing in the engine runs on drop. The
//! transport is scripted ([`ScriptedFanout`]) and sends nothing; time is a
//! clock each test sets. The only real time paid is the engine's own
//! announced deadlines where a received commit has to be applied
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

mod helpers;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use haven_core::circle::{CircleConfig, CircleManager};
use haven_core::nostr::mls::storage::{
    set_commit_retirement_fault_for_test, set_engine_write_fault_for_test,
    set_stored_message_write_fault_for_test, EngineWrite,
};
use haven_core::nostr::mls::types::{
    ConvergedRoster, EpochState, FanoutId, FanoutMls, FanoutProbe, FanoutTargetStatus, GroupEvent,
    GroupId, MessageId, MessageState, PendingStateRef, PublishWork, SessionEffects,
};
use haven_core::nostr::mls::{ChangeNote, SessionManager, StorageConfig};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    drive_due, drive_one, is_owned, DriveMode, DueOutcome, FanoutClock, FanoutStatus,
};
use haven_core::relay::{RelayError, RelayManager};
use helpers::{assert_no_needles, capture_haven_log, setup_circle, CircleFixture, CircleMember};
use nostr::JsonUtil as _;

const ONE: &str = "wss://one.restart-canary5c1e.example.com";
const TWO: &str = "wss://two.restart-canary5c1e.example.com";
const CANARY: &str = "restart-canary5c1e";

const SECOND_MS: u64 = 1_000;
const HOUR_MS: u64 = 3_600 * SECOND_MS;
const STAGED_AT: u64 = 1_700_000_000_000;

/// A clock a test sets.
struct Clock(AtomicU64);

impl Clock {
    const fn at(offset_ms: u64) -> Self {
        Self(AtomicU64::new(STAGED_AT + offset_ms))
    }

    fn set(&self, offset_ms: u64) {
        self.0.store(STAGED_AT + offset_ms, Ordering::SeqCst);
    }
}

impl FanoutClock for Clock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// A `drive_due` that no row's error cut short.
fn ran(due: DueOutcome) -> DueOutcome {
    assert!(due.error.is_none(), "the drive failed");
    due
}

fn answering(answers: &[(&str, &[Answer])]) -> ScriptedFanout {
    let transport = ScriptedFanout::default();
    for (target, script) in answers {
        transport.answer(target, script.iter().copied());
    }
    transport
}

/// `member` reopened with MDK's record of each proposal in `effects` copied
/// from `minted_by`'s store, as if its own engine had minted them.
fn with_the_record_of(
    member: CircleMember,
    minted_by: CircleMember,
    effects: &SessionEffects,
) -> CircleMember {
    use cgka_traits::storage::MessageStorage as _;
    let open = |who: CircleMember| {
        let CircleMember { circle, keys, dir } = who;
        drop(Arc::try_unwrap(circle).unwrap_or_else(|_| panic!("the manager is still shared")));
        let (db, key) = helpers::stranded::mls_db(dir.path());
        haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
        let store = storage_sqlite::SqliteAccountStorage::open_encrypted_with_options(
            &db,
            &key,
            StorageConfig::storage_options(),
        )
        .expect("the closed store opens");
        (store, keys, dir)
    };
    let (source, _, _) = open(minted_by);
    let records: Vec<_> = effects
        .publish
        .iter()
        .filter_map(|work| match work {
            PublishWork::Proposal { msg, .. } => Some(source.get_message(&msg.id).expect("minted")),
            _ => None,
        })
        .collect();
    drop(source);
    let (target, keys, dir) = open(member);
    for record in &records {
        // As `Failed`, so the admin's engine never takes it for a message of
        // its own in flight; Haven reads only its circle and epoch.
        let mut record = record.clone();
        record.state = haven_core::nostr::mls::types::MessageState::Failed;
        target.put_message(&record).expect("the record is copied");
    }
    drop(target);
    CircleMember {
        circle: Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("reopens")),
        keys,
        dir,
    }
}

fn the_one(ids: Vec<FanoutId>) -> FanoutId {
    let [id] = <[FanoutId; 1]>::try_from(ids).unwrap_or_else(|_| panic!("exactly one fanout"));
    id
}

/// Stages the removal of the circle's last member in staging mode.
async fn stage_removal(fx: &CircleFixture) -> FanoutId {
    let last = fx.members.last().expect("a member").pubkey_hex();
    the_one(
        fx.admin()
            .session()
            .remove_members_staging(&fx.group, &[last], STAGED_AT)
            .await
            .expect("the removal is staged")
            .fanouts,
    )
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

async fn rows_of(member: &CircleMember, group: &GroupId) -> Vec<FanoutId> {
    member
        .session()
        .fanout_ids_for_test(group)
        .await
        .expect("the store is read")
}

async fn staged_ref(member: &CircleMember, group: &GroupId) -> Option<PendingStateRef> {
    match member.session().epoch_state(group).await {
        Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
        _ => None,
    }
}

async fn commit_state(member: &CircleMember, event: nostr::EventId) -> Option<MessageState> {
    member
        .session()
        .stored_message_record_for_test(&MessageId::new(event.to_bytes().to_vec()))
        .await
        .expect("the store is read")
        .map(|record| record.state)
}

async fn settled_members(member: &CircleMember, group: &GroupId) -> Option<usize> {
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

fn commit_event_id(effects: &SessionEffects) -> nostr::EventId {
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

/// Whether `member` can seal a location for `group` right now.
async fn can_send(member: &CircleMember, group: &GroupId) -> bool {
    member
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await
        .is_ok()
}

/// A location `sender` seals for `group` now. A sender that cannot seal is a
/// failed test, never a reader who "cannot read".
async fn sealed_by(sender: &CircleMember, group: &GroupId) -> nostr::Event {
    sender
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(48.85, 2.35),
        )
        .await
        .unwrap_or_else(|_| panic!("the sender cannot seal a location"))
        .0
}

/// Whether `reader` reads `event`.
async fn opens(reader: &CircleMember, event: &nostr::Event) -> bool {
    reader
        .circle
        .ingest_for_test(event)
        .await
        .is_ok_and(|results| {
            results.iter().any(|result| {
                matches!(
                    result,
                    haven_core::nostr::mls::types::LocationMessageResult::Location { .. }
                )
            })
        })
}

/// Whether `reader` reads a location `sender` seals now.
async fn reads(reader: &CircleMember, sender: &CircleMember, group: &GroupId) -> bool {
    let Ok((event, _, _)) = sender
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(48.85, 2.35),
        )
        .await
    else {
        return false;
    };
    reader
        .circle
        .ingest_for_test(&event)
        .await
        .is_ok_and(|results| !results.is_empty())
}

/// A second circle of `member`'s own, alone in it.
async fn solo_circle(member: &CircleMember, relays: &[&str]) -> GroupId {
    let relays: Vec<String> = relays.iter().map(ToString::to_string).collect();
    member
        .circle
        .create_circle(
            &member.keys,
            Vec::new(),
            &CircleConfig::new("Solo").with_relays(relays.clone()),
        )
        .await
        .expect("the circle is created")
        .circle
        .mls_group_id
}

fn split(fx: CircleFixture) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let mut members = fx.members;
    let admin = members.remove(0);
    (admin, members, fx.group)
}

/// Starts a drive whose every call parks, waits until `calls` of them are
/// made, and drops it: the process dies with the event handed over and no
/// answer stored.
async fn die_mid_call(
    member: &CircleMember,
    transport: &ScriptedFanout,
    id: &FanoutId,
    calls: usize,
) {
    transport.park();
    let clock = Clock::at(0);
    let driving = drive_one(&member.circle, transport, &clock, id, &DriveMode::Full);
    tokio::pin!(driving);
    for _ in 0..calls {
        tokio::select! {
            biased;
            _ = &mut driving => panic!("the drive finished while its calls were parked"),
            () = transport.parked() => {}
        }
    }
}

// ── Resume ───────────────────────────────────────────────────────────────────

/// The process dies after the commit was handed to its relays and before any
/// answer was stored. The next process finds the commit still staged, records
/// each interrupted attempt as possibly exposed BEFORE it tries again — so no
/// later refusal can roll the commit back — and sends the same bytes.
#[tokio::test]
async fn a_hard_kill_after_send_restores_pending_publish_and_retries_the_same_bytes() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    die_mid_call(fx.admin(), &transport, &id, 2).await;
    transport.unpark();
    let _ = transport.calls();

    let (admin, _others, group) = split(fx);
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "the staged commit did not survive the process that staged it",
    );
    let stored = row(&admin, &id).await;
    assert_eq!(stored.statuses, [FanoutTargetStatus::Attempting; 2]);
    assert!(
        stored.event_id == frozen.event_id && stored.payload == frozen.payload,
        "the row a restart finds is not the one that was frozen",
    );
    assert!(is_owned(&frozen.event_id));

    // A second later every relay would refuse it. The interrupted attempts
    // are exposure first; and they are not repeated before their time.
    let clock = Clock::at(SECOND_MS);
    let mut status = None;
    let lines = capture_haven_log(async {
        status = Some(
            drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
                .await
                .expect("the drive runs")
                .status,
        );
    })
    .await;
    assert_eq!(status, Some(FanoutStatus::Unresolved));
    assert_eq!(
        row(&admin, &id).await.statuses,
        [FanoutTargetStatus::PossiblyExposed; 2],
        "an attempt the dead process began was not stored as possibly exposed",
    );
    assert_eq!(
        transport.calls().len(),
        0,
        "an interrupted attempt was repeated at once",
    );
    let line = lines
        .iter()
        .find(|line| line.message.contains("an attempt that never returned"))
        .expect("an interrupted attempt is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &admin.pubkey_hex(),
            &frozen.event_id.to_hex(),
            CANARY,
        ],
    );

    // Thirty seconds after the attempt it may be made again — refused now by
    // every relay, which proves nothing about the frames the dead process
    // sent: the commit is never rolled back.
    clock.set(30 * SECOND_MS);
    let status = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .expect("the drive runs")
        .status;
    assert_eq!(
        status,
        FanoutStatus::Unresolved,
        "a commit a dead process may have delivered was rolled back",
    );
    let again = transport.calls();
    assert_eq!(again.len(), 2);
    assert!(
        again
            .iter()
            .all(|call| call.event_id == frozen.event_id && call.payload == frozen.payload),
        "what was sent after the restart is not the frozen event, byte for byte",
    );
    assert!(staged_ref(&admin, &group).await.is_some());
    assert_eq!(
        commit_state(&admin, frozen.event_id).await,
        Some(MessageState::Sent)
    );

    // The relay that stored it says so, and the commit applies.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(2 * HOUR_MS);
    let status = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .expect("the drive runs")
        .status;
    assert_eq!(status, FanoutStatus::Confirmed);
    assert_eq!(settled_members(&admin, &group).await, Some(2));
}

/// A relay that never answered is asked again with the same event — not
/// before thirty seconds have passed, then a minute, each from the attempt
/// before.
#[tokio::test]
async fn timeout_keeps_pending_and_republishes_same_event_id() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);
    let circle = &fx.admin().circle;

    let first = drive_one(circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .expect("the drive runs");
    assert_eq!(first.status, FanoutStatus::Unresolved);
    assert_eq!(first.retry_after_ms, Some(30 * SECOND_MS));
    assert_eq!(transport.calls().len(), 2);
    assert!(staged_ref(fx.admin(), &fx.group).await.is_some());

    for (early, due) in [
        (30 * SECOND_MS - 1, 30 * SECOND_MS),
        (90 * SECOND_MS - 1, 90 * SECOND_MS),
        (210 * SECOND_MS - 1, 210 * SECOND_MS),
    ] {
        clock.set(early);
        let waiting = drive_one(circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .expect("the drive runs");
        assert_eq!(waiting.status, FanoutStatus::Unresolved);
        assert_eq!(
            transport.calls().len(),
            0,
            "a relay that had not answered was asked again before its time",
        );
        assert_eq!(waiting.retry_after_ms, Some(1));

        clock.set(due);
        assert_eq!(
            drive_one(circle, &transport, &clock, &id, &DriveMode::Full)
                .await
                .expect("the drive runs")
                .status,
            FanoutStatus::Unresolved
        );
        let again = transport.calls();
        assert_eq!(again.len(), 2, "each relay is asked again, once");
        assert!(
            again
                .iter()
                .all(|call| call.event_id == frozen.event_id && call.payload == frozen.payload),
            "the retry is not the frozen event, byte for byte",
        );
    }
    assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::Pending);
}

/// Promotes the circle's second member to admin and has it apply the change.
async fn co_admin(fx: &CircleFixture) {
    let (alice, bob) = (&fx.members[0], &fx.members[1]);
    let effects = alice
        .session()
        .update_admin_policy(
            &fx.group,
            &[
                alice.keys.public_key().to_bytes(),
                bob.keys.public_key().to_bytes(),
            ],
        )
        .await
        .expect("the promotion is staged");
    let (msg, pending) = effects
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
            _ => None,
        })
        .expect("one commit");
    alice
        .session()
        .confirm_published(pending)
        .await
        .expect("confirm");
    let event = SessionManager::transport_message_to_event(&msg).expect("a commit event");
    bob.session()
        .process_event_settled_for_test(&event)
        .await
        .expect("the second admin applies the promotion");
}

/// Two admins commit from one epoch; the second's relay stored its commit and
/// the acknowledgement never arrived; that device dies. Reopened, it still
/// holds the commit, republishes it byte for byte, and applies it on the
/// relay's answer — so when each device then receives the other's commit,
/// both settle on one branch. Run with the restarted device's key on either
/// side of the other's: which commit wins is decided by the committers' keys.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_kill_between_relay_ack_and_local_confirm_converges_on_one_branch() {
    for restarted_is_lower in [true, false] {
        let fx = setup_circle(2, &[ONE]).await;
        co_admin(&fx).await;
        let (mut first, mut second) = {
            let mut members = fx.members;
            let b = members.remove(1);
            let a = members.remove(0);
            (a, b)
        };
        if (second.keys.public_key().to_bytes() < first.keys.public_key().to_bytes())
            != restarted_is_lower
        {
            std::mem::swap(&mut first, &mut second);
        }
        let group = fx.group;

        // The first admin's commit, acknowledged and applied.
        let moved = |index: usize| {
            vec![
                ONE.to_string(),
                format!("wss://branch-{index}.{CANARY}.example.com"),
            ]
        };
        let effects = first
            .session()
            .update_relays(&group, moved(0))
            .await
            .expect("the first commit is staged");
        let (msg, pending) = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("one commit");
        first
            .session()
            .confirm_published(pending)
            .await
            .expect("the first commit is confirmed");
        let first_commit = SessionManager::transport_message_to_event(&msg).expect("a commit");

        // The second admin's, from the same epoch: sent, stored by the relay,
        // its acknowledgement lost.
        let id = the_one(
            second
                .session()
                .update_relays_staging(&group, moved(1), STAGED_AT)
                .await
                .expect("the second commit is staged")
                .fanouts,
        );
        let relay = answering(&[(ONE, &[Answer::Silent])]);
        let clock = Clock::at(0);
        assert_eq!(
            drive_one(&second.circle, &relay, &clock, &id, &DriveMode::Full)
                .await
                .expect("the drive runs")
                .status,
            FanoutStatus::Unresolved
        );
        let on_the_relay = relay.calls().remove(0);
        let second_commit =
            nostr::Event::from_json(&on_the_relay.payload).expect("the frozen event");
        assert!(
            !can_send(&second, &group).await,
            "premise: the circle's send path is shut while the commit is staged",
        );

        let second = second.reopen();
        assert!(
            !can_send(&second, &group).await && rows_of(&second, &group).await == [id.clone()],
            "after the kill the commit is no longer staged under its one row",
        );
        assert_eq!(row(&second, &id).await.event_id, second_commit.id);

        // The relay answers the same bytes: it already holds them.
        relay.answer(ONE, [Answer::Accepted]);
        clock.set(30 * SECOND_MS);
        let due = ran(drive_due(
            &second.circle,
            &relay,
            &clock,
            Some(&group),
            None,
            &DriveMode::Full,
        )
        .await);
        assert_eq!(due.driven.len(), 1);
        assert_eq!(due.driven[0].1.status, FanoutStatus::Confirmed);
        let resent = relay.calls();
        assert!(
            resent.len() == 1 && resent[0].payload == on_the_relay.payload,
            "what the restarted device sent is not the event its relay holds",
        );

        // Each now receives the other's commit, as both are on the relay.
        second
            .session()
            .process_event_settled_for_test(&first_commit)
            .await
            .expect("the restarted device ingests the first commit");
        first
            .session()
            .process_event_settled_for_test(&second_commit)
            .await
            .expect("the first device ingests the second commit");
        serve_deadlines(&second, &group).await;
        serve_deadlines(&first, &group).await;

        assert_eq!(
            first.session().epoch(&group).await.expect("epoch"),
            second.session().epoch(&group).await.expect("epoch"),
        );
        assert_eq!(
            first.session().group_relays(&group).await.expect("relays"),
            second.session().group_relays(&group).await.expect("relays"),
            "the two devices kept two different commits (restarted key lower: \
             {restarted_is_lower})",
        );
        assert!(
            reads(&first, &second, &group).await && reads(&second, &first, &group).await,
            "one epoch, two branches (restarted key lower: {restarted_is_lower})",
        );
    }
}

/// A pending ref hydrate restored is never handed out again in the session
/// that restored it: a commit staged afterwards, in another circle, is its own.
#[tokio::test]
async fn a_restored_pending_ref_never_collides_with_a_new_one() {
    let fx = setup_circle(3, &[ONE]).await;
    let elsewhere = solo_circle(fx.admin(), &[TWO]).await;
    let restored = stage_removal(&fx).await;
    let (admin, _others, group) = split(fx);
    let admin = admin.reopen();
    let restored_ref = staged_ref(&admin, &group).await.expect("restored");

    let fresh = the_one(
        admin
            .session()
            .update_relays_staging(&elsewhere, vec![ONE.to_string()], STAGED_AT)
            .await
            .expect("a commit is staged in another circle")
            .fanouts,
    );
    let fresh_ref = staged_ref(&admin, &elsewhere).await.expect("staged");
    assert!(
        fresh_ref != restored_ref,
        "a new commit was given the pending ref a restored one holds",
    );
    assert_eq!(staged_ref(&admin, &group).await, Some(restored_ref));

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let due = ran(drive_due(
        &admin.circle,
        &transport,
        &Clock::at(0),
        None,
        None,
        &DriveMode::Full,
    )
    .await);
    assert_eq!(
        due.driven
            .iter()
            .map(|(id, outcome)| (id.clone(), outcome.status))
            .collect::<Vec<_>>(),
        [
            (restored, FanoutStatus::Confirmed),
            (fresh, FanoutStatus::Confirmed)
        ],
        "every stored commit is driven, in the order they were staged",
    );
    assert_eq!(settled_members(&admin, &group).await, Some(2));
    assert_eq!(
        admin
            .session()
            .group_relays(&elsewhere)
            .await
            .expect("relays"),
        [ONE]
    );
}

// ── One driver ───────────────────────────────────────────────────────────────

/// Two wakes of one process each drive what is due: the second finds the row
/// taken and sends nothing.
#[tokio::test]
async fn two_wakes_never_drive_one_fanout_concurrently() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    transport.park();
    let clock = Clock::at(0);
    let circle = &fx.admin().circle;
    let first = drive_due(circle, &transport, &clock, None, None, &DriveMode::Full);
    tokio::pin!(first);
    for _ in 0..2 {
        tokio::select! {
            biased;
            _ = &mut first => panic!("the drive finished while its calls were parked"),
            () = transport.parked() => {}
        }
    }

    // A second wake that got in would park a call of its own.
    let second = tokio::select! {
        biased;
        due = drive_due(circle, &transport, &clock, Some(&fx.group), None, &DriveMode::Full) => Some(due),
        () = transport.parked() => None,
    }
    .map(ran)
    .expect("a second wake drove the row beside the first");
    assert_eq!(second.driven.len(), 1);
    assert_eq!(second.driven[0].1.status, FanoutStatus::Busy);
    assert_eq!(transport.call_count(), 2, "the second wake sent something");

    transport.unpark();
    let first = ran(first.await);
    assert_eq!(first.driven[0].0, id);
    assert_eq!(first.driven[0].1.status, FanoutStatus::Confirmed);
    assert_eq!(transport.most_at_once(), 1);
}

/// A second isolate is a second thread of the same process. It cannot open
/// the store while the first holds it, and through the manager they share it
/// finds the row taken.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_isolates_never_drive_one_fanout_concurrently() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = Arc::new(answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Accepted]),
    ]));
    transport.park();
    let admin = fx.admin();
    let clock = Clock::at(0);
    let first = drive_one(
        &admin.circle,
        transport.as_ref(),
        &clock,
        &id,
        &DriveMode::Full,
    );
    tokio::pin!(first);
    for _ in 0..2 {
        tokio::select! {
            biased;
            _ = &mut first => panic!("the drive finished while its calls were parked"),
            () = transport.parked() => {}
        }
    }

    let (circle, isolate_transport, isolate_id) = (
        Arc::clone(&admin.circle),
        Arc::clone(&transport),
        id.clone(),
    );
    let (dir, keys) = (admin.dir.path().to_path_buf(), admin.keys.clone());
    let isolate = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("the isolate's runtime");
        runtime.block_on(async move {
            let second_session = CircleManager::new_unencrypted(&dir, &keys).is_ok();
            let status = drive_one(
                &circle,
                isolate_transport.as_ref(),
                &Clock::at(0),
                &isolate_id,
                &DriveMode::Full,
            )
            .await
            .expect("the drive runs")
            .status;
            (second_session, status)
        })
    });
    let (second_session, status) = isolate.join().expect("the isolate ran");
    assert!(
        !second_session,
        "a second isolate opened a session on a store the first holds",
    );
    assert_eq!(status, FanoutStatus::Busy);
    assert_eq!(
        transport.call_count(),
        2,
        "the second isolate sent something"
    );

    transport.unpark();
    assert_eq!(
        first.await.expect("the drive runs").status,
        FanoutStatus::Confirmed
    );
    assert_eq!(transport.most_at_once(), 1);
}

/// A reclaim drops the references it holds; a drive under way holds one of
/// its own. Until that drive has ended the store cannot be opened again, and
/// the session that then opens it resumes the very row.
#[tokio::test]
async fn a_reclaim_during_a_drive_is_refused_and_the_reopen_resumes_the_same_row() {
    let fx = setup_circle(2, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let (admin, _others, group) = split(fx);
    let CircleMember { circle, keys, dir } = admin;
    let transport = Arc::new(answering(&[(ONE, &[Answer::Silent, Answer::Accepted])]));
    transport.park();

    let (driving_circle, driving_transport, driving_id) =
        (Arc::clone(&circle), Arc::clone(&transport), id.clone());
    let drive = tokio::spawn(async move {
        drive_one(
            &driving_circle,
            driving_transport.as_ref(),
            &Clock::at(0),
            &driving_id,
            &DriveMode::Full,
        )
        .await
        .map(|outcome| outcome.status)
    });
    transport.parked().await;

    // The reclaim: every reference but the drive's own is dropped.
    drop(circle);
    assert!(
        CircleManager::new_unencrypted(dir.path(), &keys).is_err(),
        "the store was opened a second time while a drive still held the first session",
    );

    transport.unpark();
    assert_eq!(
        drive
            .await
            .expect("the drive task")
            .expect("the drive runs"),
        FanoutStatus::Unresolved
    );
    let admin = CircleMember {
        circle: Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys)
                .expect("the store opens once the drive has ended"),
        ),
        keys,
        dir,
    };
    let resumed = row(&admin, &id).await;
    assert!(resumed.event_id == frozen.event_id && resumed.payload == frozen.payload);
    assert_eq!(resumed.statuses, [FanoutTargetStatus::PossiblyExposed]);
    let _ = transport.calls();
    let status = drive_one(
        &admin.circle,
        transport.as_ref(),
        &Clock::at(30 * SECOND_MS),
        &id,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs")
    .status;
    assert_eq!(status, FanoutStatus::Confirmed);
    assert!(transport
        .calls()
        .iter()
        .all(|call| call.payload == frozen.payload));
    assert_eq!(settled_members(&admin, &group).await, Some(1));
}

// ── What the open settles before the engine opens ────────────────────────────

/// A row's event is refused by every other publish path from the moment a
/// session opens its store — before the engine has hydrated, so before
/// anything of this process can publish at all.
#[tokio::test]
async fn the_fanout_registry_is_rebuilt_before_anything_can_publish() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let event = nostr::Event::from_json(&frozen.payload).expect("the frozen event");
    let (admin, _others, _group) = split(fx);
    let CircleMember { circle, keys, dir } = admin;
    drop(circle);
    haven_core::relay::fanout::disown_for_test(&event.id);
    assert!(!is_owned(&event.id), "premise: a new process knows nothing");

    // The bare session, as the first thing a process does.
    let session = SessionManager::new_unencrypted(dir.path(), &keys).expect("the store opens");
    assert!(is_owned(&event.id));
    let relays = RelayManager::new();
    let targets = [ONE.to_string(), TWO.to_string()];
    assert!(
        matches!(
            relays.publish_event(&event, &targets).await,
            Err(RelayError::FanoutOwned)
        ) && relays.get_relay_status().await.is_empty(),
        "after a restart the row's event was no longer the driver's alone",
    );
    drop(session);
}

/// A change that removes nobody — a relay change here; an invite, a
/// hand-over, a step-down or a repair alike — whose process died between
/// the engine's staging and its record's write never left the device:
/// nothing sends a commit without a record. MDK's hydrate clears it and
/// announces the clear; Haven retires its stored row before the first engine
/// call, so no convergence pass applies it on this device alone. The circle
/// is told the change was undone, and stays in step with its peer: the
/// epoch, the relays and what each seals for the other are as before
/// (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW, T-ROLLBACK-RESURRECT).
#[tokio::test]
async fn a_commit_cleared_at_open_is_retired_and_never_merged() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let before = admin.session().epoch(&group).await.expect("epoch");
    let staged = admin
        .session()
        .update_relays(&group, vec![TWO.to_string()])
        .await
        .expect("a relay change is staged, and no row written");
    let commit = commit_event_id(&staged);
    assert!(staged_ref(&admin, &group).await.is_some(), "premise");

    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_none() && rows_of(&admin, &group).await.is_empty(),
        "a commit that is not a removal was kept staged, or given a row, at the open",
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUndone],
        "a circle whose interrupted change the engine cleared was not told it was undone",
    );
    assert!(can_send(&admin, &group).await);

    // Every deadline served, as any receive plane serves it.
    serve_deadlines(&admin, &group).await;
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before,
        "a commit no relay was ever sent was applied on this device alone",
    );
    assert_eq!(
        admin.session().group_relays(&group).await.expect("relays"),
        [ONE],
        "the relays a change no relay was sent named took effect here",
    );
    let sealed = sealed_by(&admin, &group).await;
    assert!(
        opens(&others[0], &sealed).await,
        "what this device seals after the open, its peer cannot read",
    );
    assert_eq!(
        commit_state(&admin, commit).await,
        Some(MessageState::Failed),
        "the cleared commit's row is still a convergence input",
    );
    // Still told, and still in step, across the next start.
    let admin = admin.reopen();
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUndone]
    );
    serve_deadlines(&admin, &group).await;
    assert_eq!(admin.session().epoch(&group).await.expect("epoch"), before);
}

/// An open that cannot read what it would need to find a cleared commit
/// hands the engine to no call that could merge it: the first call is held
/// until the store answers, and then the commit is retired before it.
#[tokio::test]
async fn an_open_that_cannot_read_the_cleared_commits_holds_the_engine_until_it_can() {
    use haven_core::nostr::NostrError;
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = admin.session().epoch(&group).await.expect("epoch");
    let staged = admin
        .session()
        .update_relays(&group, vec![TWO.to_string()])
        .await
        .expect("a relay change is staged, and no row written");
    let commit = commit_event_id(&staged);
    // Unreadable at the open and at the first call's read; readable after.
    SessionManager::fail_cleared_reads_for_test(2);
    let admin = admin.reopen();
    assert!(
        matches!(
            admin.session().advance_for_receive(&group).await,
            Err(NostrError::EngineHeld)
        ),
        "the engine was handed to a call before the open knew which commit it cleared",
    );
    serve_deadlines(&admin, &group).await;
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before,
        "a commit no relay was ever sent was applied on this device alone",
    );
    assert_eq!(
        commit_state(&admin, commit).await,
        Some(MessageState::Failed),
        "the cleared commit's row is still a convergence input",
    );
}

/// The circle is told from what is STORED, in the pass before the open, not
/// from the engine's own announcement of the clear — which is made once, in
/// memory, and reaches a note only when some later engine batch is
/// collected. A process that ends between the open and that batch has told
/// its circle all the same, and so has the one after it, which the engine
/// announces nothing to.
#[tokio::test]
async fn a_change_the_open_clears_is_noted_before_anything_is_collected_from_the_engine() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    admin
        .session()
        .update_relays(&group, vec![TWO.to_string()])
        .await
        .expect("a relay change is staged, and no row written");
    assert!(staged_ref(&admin, &group).await.is_some(), "premise");
    assert!(admin.session().peek_change_notes(&group).is_empty());

    // Killed; the next process opens and collects nothing before it dies too.
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_none(),
        "premise: cleared"
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUndone],
        "a circle whose interrupted change the open cleared is told only once the \
         engine's announcement has been collected",
    );
    let admin = admin.reopen();
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUndone]
    );
}

/// What a failed engine call left emitted is not left in the engine's
/// one-shot buffer for whichever plane calls it next: the driver's engine
/// calls take it, and record every commit in it, in the hold the call was
/// made in. The engine is given something to hold by an open that cleared a
/// staged commit and announced it.
#[tokio::test]
async fn what_a_failed_engine_call_left_emitted_is_taken_in_the_same_hold() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    admin
        .session()
        .update_relays(&group, vec![TWO.to_string()])
        .await
        .expect("a relay change is staged, and no row written");
    let admin = admin.reopen();

    let taken = admin
        .session()
        .settle_a_failed_call_for_test(STAGED_AT)
        .await;
    assert!(
        taken.effects.events.iter().any(|event| matches!(
            event,
            GroupEvent::PendingCommitRecovered { group_id, .. } if *group_id == group
        )),
        "what the engine held emitted was not handed back with the failure",
    );
    let left = admin.session().drain().await;
    assert!(
        left.events.is_empty() && left.publish.is_empty(),
        "what a failed call had emitted was left in the engine's buffer for \
         the next caller of any plane",
    );
}

/// A plain rollback whose caller drops it after the rewind has landed — a
/// publish ladder cut at a wake's end is one — leaves the commit rewound and
/// its own row still stored as sent, where a convergence pass would merge a
/// commit nobody was sent. The rollback owes its finish BEFORE it rewinds,
/// so the session's next engine call retires that row before the engine is
/// handed over.
#[tokio::test]
async fn a_plain_rollback_dropped_after_its_rewind_is_finished_by_the_next_engine_call() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let staged = admin
        .session()
        .update_relays(&group, vec![ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change is staged with no record");
    let event = commit_event_id(&staged);
    let pending = staged_ref(&admin, &group).await.expect("staged");
    assert_eq!(commit_state(&admin, event).await, Some(MessageState::Sent));

    admin.session().park_next_rollback_for_test(true);
    {
        let rolling_back = admin.circle.session().publish_failed(pending);
        tokio::pin!(rolling_back);
        while admin.session().rollback_faults_left_for_test() > 0 {
            assert!(futures::poll!(&mut rolling_back).is_pending());
            tokio::task::yield_now().await;
        }
        assert!(
            futures::poll!(&mut rolling_back).is_pending(),
            "premise: the rollback is parked after its rewind",
        );
        // Dropped here, with the rewind landed and nothing retired.
    }
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && commit_state(&admin, event).await == Some(MessageState::Sent),
        "premise: rewound, and its row still stored as sent",
    );

    // Any engine call: the gate finishes the rollback first.
    let _ = admin.session().advance_for_receive(&group).await;
    assert_eq!(
        commit_state(&admin, event).await,
        Some(MessageState::Failed),
        "a rewound commit's row was left as sent for a convergence pass to merge",
    );
    assert!(staged_ref(&admin, &group).await.is_none());
}

/// The same drop, a moment earlier: before the engine rewound anything. What
/// the rollback owed in advance is not a row to retire — the commit is still
/// staged, its row is its only stored copy, and it can still be confirmed.
#[tokio::test]
async fn a_plain_rollback_dropped_before_its_rewind_leaves_its_commit_staged_and_confirmable() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = admin.session().epoch(&group).await.expect("epoch");
    let staged = admin
        .session()
        .update_relays(&group, vec![ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change is staged with no record");
    let event = commit_event_id(&staged);
    let pending = staged_ref(&admin, &group).await.expect("staged");

    admin.session().park_next_rollback_for_test(false);
    {
        let rolling_back = admin.circle.session().publish_failed(pending);
        tokio::pin!(rolling_back);
        while admin.session().rollback_faults_left_for_test() > 0 {
            assert!(futures::poll!(&mut rolling_back).is_pending());
            tokio::task::yield_now().await;
        }
        assert!(futures::poll!(&mut rolling_back).is_pending());
    }
    assert_eq!(
        staged_ref(&admin, &group).await,
        Some(pending),
        "premise: nothing was rewound",
    );

    let _ = admin.session().advance_for_receive(&group).await;
    assert_eq!(
        commit_state(&admin, event).await,
        Some(MessageState::Sent),
        "the row of a commit that is still staged was retired",
    );
    admin
        .circle
        .session()
        .confirm_published(pending)
        .await
        .expect("the commit is still this device's to confirm");
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before + 1,
    );
}

/// The engine's rollback is stored and the process dies before the commit's
/// own row is retired. The next open finishes it BEFORE the engine hydrates:
/// no convergence pass ever sees the rolled-back commit as a candidate.
#[tokio::test]
async fn a_kill_between_fanout_rollback_and_retirement_still_retires_on_reopen() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let before = fx.admin().session().epoch(&fx.group).await.expect("epoch");
    let id = the_one(
        fx.admin()
            .session()
            .update_relays_staging(&fx.group, vec![TWO.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged")
            .fanouts,
    );
    let frozen = row(fx.admin(), &id).await;
    let (db, key) = db_of(fx.admin());
    let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), true).expect("arm");
    let status = drive_one(
        &fx.admin().circle,
        &refusing,
        &Clock::at(0),
        &id,
        &DriveMode::Full,
    )
    .await
    .expect("the drive runs")
    .status;
    set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), false)
        .expect("disarm");
    assert_eq!(status, FanoutStatus::RolledBack);
    assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::RolledBack);
    assert_eq!(
        commit_state(fx.admin(), frozen.event_id).await,
        Some(MessageState::Sent),
        "premise: the kill fell before the commit's row was retired",
    );

    let (admin, _others, group) = split(fx);
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");
    assert!(
        probe(&admin, &id).await.is_none(),
        "the finished row was kept"
    );
    assert!(!is_owned(&frozen.event_id));
    assert_eq!(
        commit_state(&admin, frozen.event_id).await,
        Some(MessageState::Failed),
        "the rolled-back commit can still be selected by a convergence pass",
    );
    let line = lines
        .iter()
        .find(|line| line.message.contains("a rollback an earlier session began"))
        .expect("finishing a rollback at the open is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &frozen.event_id.to_hex(),
            CANARY,
        ],
    );
    serve_deadlines(&admin, &group).await;
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before,
        "a commit every relay refused was merged after the restart",
    );
    assert_eq!(
        admin.session().group_relays(&group).await.expect("relays"),
        [ONE, TWO]
    );
}

/// Within a circle, nothing staged after a commit that is still pending is
/// sent before that commit is resolved, and the relay's one call per wait is
/// the commit's. A proposal recorded at the epoch the commit leaves — ahead
/// of the commit or behind it — is spent once the commit is applied, and is
/// never sent: its record names its epoch (MDK's `MessageRecord`).
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn nothing_staged_after_a_pending_commit_is_sent_before_it_is_resolved() {
    for proposal_first in [false, true] {
        let fx = setup_circle(3, &[ONE]).await;
        let (admin, mut others, group) = split(fx);
        // A proposal of this circle, for the staging step to record. A
        // proposal is recorded for the circle MDK's own record of it names,
        // and an admin mints none (it cannot leave), so the record the
        // proposing member's engine wrote is put in the admin's store.
        let leaver = others.remove(0);
        let leave = leaver
            .session()
            .leave_group(&group)
            .await
            .expect("a leave is proposed")
            .expect("a fresh leave");
        let admin = with_the_record_of(admin, leaver, &leave);
        let proposal = SessionEffects {
            events: Vec::new(),
            publish: leave
                .publish
                .into_iter()
                .filter(|work| matches!(work, PublishWork::Proposal { .. }))
                .collect(),
            queued: Vec::new(),
            pending_convergence: Vec::new(),
        };
        assert_eq!(proposal.publish.len(), 1, "premise");
        let record_proposal = |effects: SessionEffects| async {
            the_one(
                admin
                    .session()
                    .stage_commits_for_test(effects, STAGED_AT)
                    .await
                    .proposals,
            )
        };
        let stage_commit = || async {
            the_one(
                admin
                    .session()
                    .update_relays_staging(&group, vec![TWO.to_string()], STAGED_AT)
                    .await
                    .expect("a relay change is staged")
                    .fanouts,
            )
        };
        let (commit, proposed) = if proposal_first {
            let proposed = record_proposal(proposal).await;
            (stage_commit().await, proposed)
        } else {
            let commit = stage_commit().await;
            (commit, record_proposal(proposal).await)
        };
        let commit_event = row(&admin, &commit).await.event_id;
        let proposal_event = row(&admin, &proposed).await.event_id;
        assert_eq!(row(&admin, &proposed).await.mls, FanoutMls::NotApplicable);

        // No relay answers: the commit stays pending. The relay's one call
        // is the commit's wherever the proposal stands — a proposal makes no
        // call of its own inside a relay's wait.
        let transport = answering(&[(ONE, &[Answer::Silent])]);
        let clock = Clock::at(0);
        let _ = drive_due(
            &admin.circle,
            &transport,
            &clock,
            None,
            None,
            &DriveMode::Full,
        )
        .await;
        let sent: Vec<_> = transport.calls().iter().map(|call| call.event_id).collect();
        assert_eq!(
            sent,
            [commit_event],
            "the relay's one call did not go to the pending commit, or the proposal was \
             sent inside the relay's wait",
        );

        // The relay takes the commit, and the circle leaves the epoch the
        // proposal was made at: wherever it was staged, the proposal is spent
        // and never sent — a stale proposal no member could apply.
        transport.answer(ONE, [Answer::Accepted]);
        clock.set(31_000);
        let _ = drive_due(
            &admin.circle,
            &transport,
            &clock,
            None,
            None,
            &DriveMode::Full,
        )
        .await;
        assert!(
            staged_ref(&admin, &group).await.is_none(),
            "premise: the commit is applied"
        );
        let with_the_commit: Vec<_> = transport.calls().iter().map(|call| call.event_id).collect();
        clock.set(32_000);
        let _ = drive_due(
            &admin.circle,
            &transport,
            &clock,
            None,
            None,
            &DriveMode::Full,
        )
        .await;
        let later: Vec<_> = transport.calls().iter().map(|call| call.event_id).collect();
        assert!(
            with_the_commit == [commit_event] && later.is_empty(),
            "a proposal was sent beside or after the commit that moved its circle past the epoch \
             it was made at (staged {}: {with_the_commit:?}, then {later:?}; proposal \
             {proposal_event:?})",
            if proposal_first { "ahead" } else { "behind" },
        );
    }
}

/// A change the driver undid is told to its circle whoever finishes the
/// rollback. The engine stores the rollback first; a process that dies right
/// after it has noted nothing, and the row that says a commit was undone is
/// about to be deleted by whichever pass finishes the job — the next engine
/// call of the same session, or the pass before the next open. Each writes
/// the note before the row goes. And reading a note is not taking it: a
/// process that dies after reading is handed it again.
#[tokio::test]
async fn an_interrupted_rollbacks_note_is_written_by_whoever_finishes_it() {
    for at_the_open in [true, false] {
        let fx = setup_circle(2, &[ONE, TWO]).await;
        let (admin, _others, group) = split(fx);
        let id = the_one(
            admin
                .session()
                .update_relays_staging(&group, vec![TWO.to_string()], STAGED_AT)
                .await
                .expect("a relay change is staged")
                .fanouts,
        );
        let frozen = row(&admin, &id).await;
        let (db, key) = db_of(&admin);
        let refusing = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
        set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), true)
            .expect("arm");
        let status = drive_one(
            &admin.circle,
            &refusing,
            &Clock::at(0),
            &id,
            &DriveMode::Full,
        )
        .await
        .expect("the drive runs")
        .status;
        set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), false)
            .expect("disarm");
        assert_eq!(status, FanoutStatus::RolledBack);
        assert_eq!(row(&admin, &id).await.mls, FanoutMls::RolledBack);
        // As a process that died the moment the engine had stored the
        // rollback leaves it: the row, and no note.
        let _ = admin.session().take_change_notes(&group);

        let admin = if at_the_open {
            admin.reopen()
        } else {
            let _ = admin.session().advance_for_receive(&group).await;
            admin
        };
        assert!(
            probe(&admin, &id).await.is_none(),
            "premise: the rollback was finished (at the open: {at_the_open})",
        );
        assert_eq!(
            admin.session().peek_change_notes(&group),
            [ChangeNote::ChangeUndone],
            "a rollback finished after its drive told the circle nothing \
             (at the open: {at_the_open})",
        );

        let admin = admin.reopen();
        let untold = admin.session().change_notice(&group);
        assert_eq!(
            untold.notes,
            [ChangeNote::ChangeUndone],
            "a note that was read and not acknowledged was gone after a restart",
        );
        admin.session().acknowledge_change_notice(&group, &untold);
        assert!(admin.session().peek_change_notes(&group).is_empty());
    }
}

/// When the pass before the open cannot do its work, it says so — and the
/// events of the rows it found are still nobody's but the driver's.
#[tokio::test]
async fn a_failed_settlement_before_the_open_is_reported_and_the_rows_stay_owned() {
    let fx = setup_circle(2, &[ONE]).await;
    let id = the_one(
        fx.admin()
            .session()
            .update_relays_staging(&fx.group, vec![TWO.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged")
            .fanouts,
    );
    let frozen = row(fx.admin(), &id).await;
    let (db, key) = db_of(fx.admin());
    set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), true).expect("arm");
    let refusing = answering(&[(ONE, &[Answer::Refused])]);
    let _ = drive_one(
        &fx.admin().circle,
        &refusing,
        &Clock::at(0),
        &id,
        &DriveMode::Full,
    )
    .await;
    set_commit_retirement_fault_for_test(&db, &key, frozen.event_id.as_bytes(), false)
        .expect("disarm");
    assert_eq!(row(fx.admin(), &id).await.mls, FanoutMls::RolledBack);

    let (admin, _others, group) = split(fx);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, true).expect("arm");
    haven_core::relay::fanout::disown_for_test(&frozen.event_id);
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, false).expect("disarm");
    let admin = reopened.expect("the open itself does not fail");
    let line = lines
        .iter()
        .find(|line| line.message.contains("before the open failed"))
        .expect("a settlement that failed is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &frozen.event_id.to_hex(),
            CANARY,
        ],
    );
    assert!(
        is_owned(&frozen.event_id),
        "a row the open could not settle left its event free to be sent",
    );
    // The commit's row was retired before the delete failed, and the next
    // drive finishes the row.
    assert_eq!(
        drive_one(
            &admin.circle,
            &refusing,
            &Clock::at(HOUR_MS),
            &id,
            &DriveMode::Full
        )
        .await
        .expect("the drive runs")
        .status,
        FanoutStatus::RolledBack
    );
    assert!(probe(&admin, &id).await.is_none());
}

/// A row with nothing staged behind it and nothing ever sent under it — a
/// trial record the open wrote on a guess and a kill then orphaned looks the
/// same — is abandoned by the open: its commit's row retired, the row gone.
#[tokio::test]
async fn a_record_with_nothing_staged_behind_it_is_abandoned_at_the_open() {
    let fx = setup_circle(3, &[ONE]).await;
    let before = fx.admin().session().epoch(&fx.group).await.expect("epoch");
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    let pending = staged_ref(fx.admin(), &fx.group).await.expect("staged");
    let (db, key) = db_of(fx.admin());
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = fx
        .admin()
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert_eq!(
        commit_state(fx.admin(), frozen.event_id).await,
        Some(MessageState::Sent),
        "premise: rewound, and still stored as sent",
    );

    let (admin, _others, group) = split(fx);
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");
    assert!(probe(&admin, &id).await.is_none() && !is_owned(&frozen.event_id));
    assert_eq!(
        commit_state(&admin, frozen.event_id).await,
        Some(MessageState::Failed)
    );
    let line = lines
        .iter()
        .find(|line| {
            line.message
                .contains("nothing staged behind it was removed at the open")
        })
        .expect("abandoning a record at the open is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &frozen.event_id.to_hex(),
            CANARY,
        ],
    );
    serve_deadlines(&admin, &group).await;
    assert_eq!(admin.session().epoch(&group).await.expect("epoch"), before);
    assert!(can_send(&admin, &group).await);
}

// ── A removal a kill left staged with no record ──────────────────────────────

/// The state MDK's hydrate cannot recover from: a removal the user asked for,
/// staged with no fanout row. Unrepaired, an admin's own Remove stops every
/// convergence pass of the circle on this device for good (T-KILL-WINDOW).
/// The open gives the removal its record before the engine hydrates, and the
/// engine restores it like any staged commit. (An eviction is not given one
/// while nothing the app calls drives a record: without it the circle is
/// healed by another member's commit —
/// `an_eviction_a_kill_left_with_no_record_is_healed_by_another_members_commit`.)
///
/// What nobody can know is whether the commit already left the device:
/// whoever staged it with no record may have published it before the process
/// died. So the record says every relay MAY hold it. A relay that does
/// answers that it already has it, and the removal is applied — on this
/// device, on a peer that applies the same event, and against the removed
/// member, who can no longer read. A relay that refuses it proves nothing
/// about the publish that may have gone before: the removal stays staged,
/// whatever every relay says and for however long.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_removal_a_kill_left_staged_with_no_record_is_given_one_at_the_open() {
    {
        for held_by_a_relay in [true, false] {
            let fx = setup_circle(3, &[ONE, TWO]).await;
            let (admin, others, group) = split(fx);
            assert!(
                opens(&others[1], &sealed_by(&admin, &group).await).await,
                "premise: the member about to be removed reads the circle",
            );
            // The shipped path: the commit is handed back to be published,
            // and the process may die after it was.
            let commit = commit_event_id(
                &admin
                    .session()
                    .remove_members(&group, &[others[1].pubkey_hex()])
                    .await
                    .expect("a removal is staged, and no row written"),
            );
            assert!(rows_of(&admin, &group).await.is_empty(), "premise: no row");

            let mut reopened = None;
            let lines = capture_haven_log(async {
                reopened = Some(admin.reopen());
            })
            .await;
            let admin = reopened.expect("reopened");
            let id = the_one(rows_of(&admin, &group).await);
            let given = row(&admin, &id).await;
            assert_eq!(
                given.event_id, commit,
                "the record is not the staged removal's own signed event",
            );
            assert_eq!(given.targets, [ONE, TWO]);
            assert_eq!(given.required_acks, 2);
            assert_eq!(
                given.statuses,
                [FanoutTargetStatus::PossiblyExposed; 2],
                "a commit of unknown history was recorded as never sent",
            );
            assert_eq!(given.mls, FanoutMls::Pending);
            assert!(
                staged_ref(&admin, &group).await.is_some(),
                "the engine does not hold the removal under its record",
            );
            assert!(is_owned(&commit));
            let line = lines
                .iter()
                .find(|line| line.message.contains("was given one"))
                .expect("the repair is reported");
            assert_no_needles(
                std::slice::from_ref(line),
                &[
                    &hex::encode(group.as_slice()),
                    &admin.pubkey_hex(),
                    &commit.to_hex(),
                    CANARY,
                ],
            );

            // Every relay refuses it, drive after drive, past any bound: a
            // refusal now says nothing about a publish that may have gone
            // before, and the removal is never undone.
            let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
            let clock = Clock::at(HOUR_MS);
            for hours in [1, 3, 30, 24 * 40] {
                clock.set(hours * HOUR_MS);
                let due = ran(drive_due(
                    &admin.circle,
                    &transport,
                    &clock,
                    Some(&group),
                    None,
                    &DriveMode::Full,
                )
                .await);
                assert_eq!(due.driven[0].1.status, FanoutStatus::Unresolved);
            }
            let refused = transport.calls();
            assert!(
                !refused.is_empty() && refused.iter().all(|call| call.event_id == commit),
                "premise: the relays were asked, and for this commit",
            );
            assert!(
                staged_ref(&admin, &group).await.is_some()
                    && commit_state(&admin, commit).await == Some(MessageState::Sent),
                "a removal a relay may hold was rolled back",
            );
            if !held_by_a_relay {
                continue;
            }

            // One relay holds it — the publish that went before the kill —
            // and says so: the removal is applied.
            transport.answer(ONE, [Answer::Accepted]);
            clock.set(24 * 80 * HOUR_MS);
            let due = ran(drive_due(
                &admin.circle,
                &transport,
                &clock,
                Some(&group),
                None,
                &DriveMode::Full,
            )
            .await);
            assert_eq!(due.driven[0].1.status, FanoutStatus::Confirmed);
            let sent = transport.calls();
            assert!(sent.iter().all(|call| call.event_id == commit));
            serve_deadlines(&admin, &group).await;
            assert_eq!(settled_members(&admin, &group).await, Some(2));
            assert!(
                can_send(&admin, &group).await,
                "the circle does not work after the repair",
            );

            // A peer applies the very event the relay holds, and reads what
            // the repaired device seals afterwards; the removed member
            // cannot.
            let event = nostr::Event::from_json(&sent[0].payload).expect("the frozen event");
            let (peer, removed) = (&others[0], &others[1]);
            peer.session()
                .process_event_settled_for_test(&event)
                .await
                .expect("the peer applies the repaired removal");
            assert_eq!(settled_members(peer, &group).await, Some(2));
            // ONE event, sealed after the removal: the remaining member
            // reads it and the removed one does not.
            let after = sealed_by(&admin, &group).await;
            assert!(
                opens(peer, &after).await,
                "a remaining member cannot read the repaired device",
            );
            let _ = removed
                .session()
                .process_event_settled_for_test(&event)
                .await;
            assert!(
                !opens(removed, &after).await,
                "a member removed by a repaired removal still reads the circle",
            );

            // And it takes a change again.
            let again = admin
                .session()
                .update_relays_staging(&group, vec![ONE.to_string()], STAGED_AT)
                .await
                .expect("a change is staged");
            assert_eq!(again.fanouts.len(), 1);
        }
    }
}

/// A repaired removal that could not be given its relays — the record's
/// re-freeze failed — is frozen for nobody, and that proves nothing: it is
/// not rolled back. It stays staged, said so once, and the next open gives it
/// its relays.
#[tokio::test]
async fn a_repaired_removal_that_could_not_be_given_its_relays_is_never_rolled_back() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let commit = commit_event_id(
        &admin
            .session()
            .remove_members(&group, &[others[1].pubkey_hex()])
            .await
            .expect("a removal is staged, and no row written"),
    );
    let (db, key) = db_of(&admin);
    // The trial's own write is an insert; giving it its relays deletes it
    // first, and that delete is what fails.
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, true).expect("arm");
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, false).expect("disarm");
    let admin = reopened.expect("reopened");
    let id = the_one(rows_of(&admin, &group).await);
    assert!(
        row(&admin, &id).await.targets.is_empty() && staged_ref(&admin, &group).await.is_some(),
        "premise: the removal is held under a record frozen for no relay",
    );
    let line = lines
        .iter()
        .find(|line| line.message.contains("could not be given its relays"))
        .expect("a repair that stopped half way is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[&hex::encode(group.as_slice()), &commit.to_hex(), CANARY],
    );

    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    let clock = Clock::at(HOUR_MS);
    for hours in [1, 30] {
        clock.set(hours * HOUR_MS);
        let outcome = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .expect("the drive runs");
        assert_eq!(outcome.status, FanoutStatus::Unresolved);
    }
    assert_eq!(transport.calls().len(), 0);
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && commit_state(&admin, commit).await == Some(MessageState::Sent),
        "a removal whose record names no relay was rolled back",
    );

    let admin = admin.reopen();
    let id = the_one(rows_of(&admin, &group).await);
    assert_eq!(row(&admin, &id).await.targets, [ONE, TWO]);
    transport.answer(ONE, [Answer::Accepted]);
    let outcome = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .expect("the drive runs");
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert_eq!(settled_members(&admin, &group).await, Some(2));
}

/// A trial record the engine does not hold says nothing about its commit —
/// whoever staged that commit may have published it. The record is taken
/// back, by the open or by a drive, and the commit's own row is left exactly
/// as it was found: never retired on a trial's word.
#[tokio::test]
async fn a_trial_record_the_engine_does_not_hold_is_taken_back_and_its_commit_left_as_found() {
    for at_the_open in [false, true] {
        let fx = setup_circle(3, &[ONE, TWO]).await;
        let (admin, others, group) = split(fx);
        let commit = commit_event_id(
            &admin
                .session()
                .remove_members(&group, &[others[1].pubkey_hex()])
                .await
                .expect("a removal is staged, and no row written"),
        );
        let (db, key) = db_of(&admin);
        // Adopted, and not given its relays: the record is still the trial.
        set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, true).expect("arm");
        let admin = admin.reopen();
        set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, false)
            .expect("disarm");
        let id = the_one(rows_of(&admin, &group).await);
        assert!(
            row(&admin, &id).await.targets.is_empty(),
            "premise: a trial"
        );
        // The engine lets go of the commit, and its row stays stored as sent.
        let pending = staged_ref(&admin, &group).await.expect("staged");
        set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
        let _ = admin
            .session()
            .publish_failed_past_its_fanout_for_test(pending)
            .await;
        set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
        assert!(
            staged_ref(&admin, &group).await.is_none()
                && commit_state(&admin, commit).await == Some(MessageState::Sent),
            "premise: nothing is staged behind the trial, and its commit is stored as sent",
        );

        let admin = if at_the_open {
            let mut reopened = None;
            let lines = capture_haven_log(async {
                reopened = Some(admin.reopen());
            })
            .await;
            let line = lines
                .iter()
                .find(|line| line.message.contains("was taken back at the open"))
                .expect("taking a trial back is reported");
            assert_no_needles(
                std::slice::from_ref(line),
                &[&hex::encode(group.as_slice()), &commit.to_hex(), CANARY],
            );
            reopened.expect("reopened")
        } else {
            let transport = answering(&[(ONE, &[Answer::Accepted])]);
            let outcome = drive_one(
                &admin.circle,
                &transport,
                &Clock::at(HOUR_MS),
                &id,
                &DriveMode::Full,
            )
            .await
            .expect("the drive runs");
            assert_eq!(outcome.status, FanoutStatus::Stale);
            assert_eq!(transport.calls().len(), 0);
            admin
        };
        assert!(probe(&admin, &id).await.is_none() && !is_owned(&commit));
        assert_eq!(
            commit_state(&admin, commit).await,
            Some(MessageState::Sent),
            "a commit was retired on the word of a trial record (at the open: {at_the_open})",
        );
    }
}

/// A second circle of `admin`'s, with one more member in it.
async fn second_circle(admin: &CircleMember, relays: &[&str]) -> (GroupId, CircleMember) {
    let relays: Vec<String> = relays.iter().map(ToString::to_string).collect();
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let member = CircleMember::new();
    let invited = vec![haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            member.session(),
            &member.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox.clone(),
        nip65_relays: Vec::new(),
    }];
    let created = admin
        .circle
        .create_circle(
            &admin.keys,
            invited,
            &CircleConfig::new("Second").with_relays(relays.clone()),
        )
        .await
        .expect("the circle is created");
    // As the app's driven create leaves it: the founding Welcomes sent from
    // their records and acknowledged, so no later drive sends them.
    let _ = admin.circle.land_staged_for_test().await;
    let welcome = &created.welcome_events[0];
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome.event)
        .await
        .expect("the invitation is held");
    member
        .circle
        .accept_invitation(&welcome.event.id)
        .await
        .expect("the member joins");
    (created.circle.mls_group_id, member)
}

/// Two circles each left with a removal staged and no record: each is given a
/// record of its own, under a pending ref of its own, and each is resolved
/// without touching the other.
#[tokio::test]
async fn two_removals_left_staged_in_two_circles_are_each_given_their_own_record() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, first) = split(fx);
    let (second, other) = second_circle(&admin, &[TWO]).await;
    for (group, member) in [(&first, &others[0]), (&second, &other)] {
        admin
            .session()
            .remove_members(group, &[member.pubkey_hex()])
            .await
            .expect("a removal is staged, and no row written");
    }

    let admin = admin.reopen();
    let (one, two) = (
        staged_ref(&admin, &first)
            .await
            .expect("the first is restored"),
        staged_ref(&admin, &second)
            .await
            .expect("the second is restored"),
    );
    assert!(
        one != two,
        "two circles' repaired removals were given one pending ref",
    );
    // The first circle's relay holds its removal; the second's refuses, which
    // undoes nothing: a repaired removal may have been published before.
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Refused])]);
    let clock = Clock::at(HOUR_MS);
    // By circle: the two trials are written in the store's own group order.
    let (row_of_first, row_of_second) = (
        the_one(rows_of(&admin, &first).await),
        the_one(rows_of(&admin, &second).await),
    );
    let due = ran(drive_due(
        &admin.circle,
        &transport,
        &clock,
        None,
        None,
        &DriveMode::Full,
    )
    .await);
    let status_of = |row: &FanoutId| {
        due.driven
            .iter()
            .find(|(id, _)| id == row)
            .map(|(_, outcome)| outcome.status)
    };
    assert_eq!(due.driven.len(), 2);
    assert_eq!(status_of(&row_of_first), Some(FanoutStatus::Confirmed));
    assert_eq!(status_of(&row_of_second), Some(FanoutStatus::Unresolved));
    assert_eq!(settled_members(&admin, &first).await, Some(1));
    assert!(can_send(&admin, &first).await);
    assert_eq!(
        staged_ref(&admin, &second).await,
        Some(two),
        "resolving one circle's repaired removal touched the other's",
    );
    transport.answer(TWO, [Answer::Accepted]);
    clock.set(3 * HOUR_MS);
    let due = ran(drive_due(
        &admin.circle,
        &transport,
        &clock,
        None,
        None,
        &DriveMode::Full,
    )
    .await);
    assert_eq!(due.driven.len(), 1);
    assert_eq!(due.driven[0].1.status, FanoutStatus::Confirmed);
    assert_eq!(settled_members(&admin, &second).await, Some(1));
    assert!(can_send(&admin, &second).await);
}

// ── Pacing ───────────────────────────────────────────────────────────────────

/// The whole of what one relay is sent while it keeps failing, with three
/// circles each owing it a commit and two planes driving them at once: ten
/// calls in the hour after its first failure, and one an hour after that —
/// not three or six times as many.
///
/// Each commit's FIRST call is made at once, whatever another commit's
/// failures have earned the relay: a new removal is not held back by an
/// unrelated back-off. Those calls are part of the ten, not on top of them:
/// each counts against the relay like any other, so the first RETRY waits as
/// long as three failures warrant.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_relay_is_called_on_one_schedule_however_many_rows_owe_it() {
    for (answer, first_hour, first_retry_s) in [
        (Answer::Unreachable, 10, 5),
        (Answer::Silent, 7, 120),
        (Answer::RateLimited, 6, 240),
    ] {
        let admin = CircleMember::new();
        let mut rows = Vec::new();
        for _ in 0..3 {
            let group = solo_circle(&admin, &[ONE]).await;
            rows.push(the_one(
                admin
                    .session()
                    .update_relays_staging(
                        &group,
                        vec![ONE.to_string(), TWO.to_string()],
                        STAGED_AT,
                    )
                    .await
                    .expect("a relay change is staged")
                    .fanouts,
            ));
        }
        let transport = answering(&[(ONE, &[answer])]);
        let clock = Clock::at(0);
        // Every second for the first minute, where the waits are shortest;
        // every five until the last wait under an hour has passed; then every
        // minute.
        let mut call_times: Vec<u64> = Vec::new();
        let mut at = 0;
        while at < 4 * HOUR_MS {
            clock.set(at);
            let (a, b) = tokio::join!(
                drive_due(
                    &admin.circle,
                    &transport,
                    &clock,
                    None,
                    None,
                    &DriveMode::Full
                ),
                drive_due(
                    &admin.circle,
                    &transport,
                    &clock,
                    None,
                    None,
                    &DriveMode::Full
                ),
            );
            let (a, b) = (ran(a), ran(b));
            assert!(
                a.driven
                    .iter()
                    .chain(&b.driven)
                    .all(|(_, outcome)| matches!(
                        outcome.status,
                        FanoutStatus::Unresolved | FanoutStatus::Busy
                    )),
                "a relay that never accepted resolved a commit",
            );
            for _ in transport.calls() {
                call_times.push(at);
            }
            at += match at {
                at if at < 60 * SECOND_MS => SECOND_MS,
                at if at < 40 * 60 * SECOND_MS => 5 * SECOND_MS,
                _ => 60 * SECOND_MS,
            };
        }
        let in_first_hour = call_times.iter().filter(|at| **at < HOUR_MS).count();
        assert_eq!(
            in_first_hour, first_hour,
            "calls to one relay in its first hour, three rows owing it ({answer:?})",
        );
        assert!(
            call_times[..rows.len()].iter().all(|at| *at == 0),
            "a commit's first call waited behind another commit's back-off ({answer:?})",
        );
        assert!(
            call_times[rows.len()] >= first_retry_s * SECOND_MS,
            "the first retry came after {} ms ({answer:?})",
            call_times[rows.len()],
        );
        for hour in 1..4 {
            let calls = call_times
                .iter()
                .filter(|at| **at >= hour * HOUR_MS && **at < (hour + 1) * HOUR_MS)
                .count();
            assert!(
                calls <= 1,
                "{calls} calls to one relay in hour {} ({answer:?})",
                hour + 1,
            );
        }
        assert!(
            call_times.len() > first_hour,
            "premise: the relay is still tried after its first hour",
        );
        // No row was starved: once the relay answers, every row that waited
        // on it is sent, each once, in one pass.
        transport.answer(ONE, [Answer::Accepted]);
        clock.set(6 * HOUR_MS);
        let recovered = ran(drive_due(
            &admin.circle,
            &transport,
            &clock,
            None,
            None,
            &DriveMode::Full,
        )
        .await);
        assert!(
            recovered.driven.len() == rows.len()
                && recovered
                    .driven
                    .iter()
                    .all(|(_, outcome)| outcome.status == FanoutStatus::Confirmed),
            "a relay that is answering again was not given the rows that waited on it",
        );
        assert_eq!(transport.calls().len(), rows.len());
    }
}

/// A terminal answer ends a target for good: a relay that proved it refused
/// the event, or that Haven will not dial, is never sent it again.
#[tokio::test]
async fn a_relay_that_refused_an_event_is_never_sent_it_again() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);
    for step in 0..6 {
        clock.set(step * 2 * HOUR_MS);
        assert_eq!(
            drive_one(
                &fx.admin().circle,
                &transport,
                &clock,
                &id,
                &DriveMode::Full
            )
            .await
            .expect("the drive runs")
            .status,
            FanoutStatus::Unresolved
        );
    }
    let calls = transport.calls();
    assert_eq!(
        calls.iter().filter(|call| call.target == ONE).count(),
        1,
        "a relay that proved its refusal was asked again",
    );
    assert_eq!(calls.iter().filter(|call| call.target == TWO).count(), 6);
}

/// A removal that had its record — staged in staging mode, killed after it
/// was sent, resumed by the next process — removes: a peer applies the very
/// event the relay holds, and what the resumed device seals afterwards the
/// remaining member reads and the removed member, who read the circle
/// before, does not.
#[tokio::test]
async fn a_member_removed_by_a_resumed_removal_can_no_longer_read() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let (peer, removed) = (&others[0], &others[1]);
    assert!(
        opens(removed, &sealed_by(&admin, &group).await).await,
        "premise: the member about to be removed reads the circle",
    );
    let id = the_one(
        admin
            .session()
            .remove_members_staging(&group, &[removed.pubkey_hex()], STAGED_AT)
            .await
            .expect("the removal is staged")
            .fanouts,
    );
    // Sent, the acknowledgement lost, the process killed.
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let clock = Clock::at(0);
    let _ = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full).await;
    let admin = admin.reopen();
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        None,
        None,
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none());
    assert_eq!(due.driven[0].1.status, FanoutStatus::Confirmed);
    let sent = transport.calls();
    let event = nostr::Event::from_json(&sent.last().expect("sent again").payload)
        .expect("the frozen event");

    peer.session()
        .process_event_settled_for_test(&event)
        .await
        .expect("the peer applies the resumed removal");
    assert_eq!(settled_members(peer, &group).await, Some(2));
    let after = sealed_by(&admin, &group).await;
    assert!(
        opens(peer, &after).await,
        "a remaining member cannot read the resumed device",
    );
    let _ = removed
        .session()
        .process_event_settled_for_test(&event)
        .await;
    assert!(
        !opens(removed, &after).await,
        "a member removed by a resumed removal still reads the circle",
    );
}

/// A circle whose routing component names no relay this device may dial —
/// another client's admin wrote it — cannot give a repaired commit its
/// relays. The record stays frozen for nobody, which proves nothing about
/// the commit: it is not rolled back and nothing is sent, and the open says
/// so in a line that names nothing.
#[tokio::test]
async fn a_repaired_commit_whose_circle_names_no_dialable_relay_stays_staged_and_is_said_so() {
    use cgka_traits::app_components::{
        encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
    };
    use haven_core::nostr::mls::types::{AppComponentData, SendIntent};

    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let session = admin.session();
    // Written straight to the engine, past Haven's own validation.
    let (nostr_group_id, _) = session.group_routing(&group).await.expect("routing");
    let refused = "ws://refused-entry.restart-canary5c1e.invalid";
    let routing = NostrRoutingV1::new(nostr_group_id, vec![refused.to_string()])
        .expect("MDK admits a plaintext relay");
    let foreign = session
        .send(SendIntent::UpdateAppComponents {
            group_id: group.clone(),
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
    let commit = commit_event_id(
        &session
            .remove_members(&group, &[others[1].pubkey_hex()])
            .await
            .expect("a removal is staged, and no record written"),
    );

    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");
    let line = lines
        .iter()
        .find(|line| line.message.contains("could not be given its relays"))
        .expect("a record that could not be given its relays is reported");
    assert_no_needles(
        std::slice::from_ref(line),
        &[
            &hex::encode(group.as_slice()),
            &commit.to_hex(),
            &admin.pubkey_hex(),
            CANARY,
        ],
    );
    let id = the_one(rows_of(&admin, &group).await);
    let frozen = row(&admin, &id).await;
    assert!(
        frozen.targets.is_empty() && frozen.mls == FanoutMls::Pending,
        "a record was frozen for a relay this device may not dial",
    );
    assert!(staged_ref(&admin, &group).await.is_some());

    let transport = ScriptedFanout::default();
    for hours in [1, 30] {
        let outcome = drive_one(
            &admin.circle,
            &transport,
            &Clock::at(hours * HOUR_MS),
            &id,
            &DriveMode::Full,
        )
        .await
        .expect("the drive runs");
        assert_eq!(
            outcome.status,
            FanoutStatus::Unresolved,
            "a commit frozen for no relay was resolved",
        );
    }
    assert_eq!(transport.calls().len(), 0);
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && commit_state(&admin, commit).await == Some(MessageState::Sent),
        "a repaired commit that could not be given its relays was rolled back",
    );
}

/// A circle has one mark for "its recorded commit removes nobody", so a
/// record written at the open must take it back as every other record's
/// writer does: a relay change is marked and applied, and the removal a kill
/// then leaves staged — given its record by the next open — must not read as
/// a change a day without relays may undo. Its record is stored as possibly
/// exposed, which already keeps it; the mark is the second lock on that door.
#[tokio::test]
async fn a_removal_given_its_record_at_the_open_does_not_inherit_its_circles_mark() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let accepting = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let change = the_one(
        admin
            .session()
            .update_relays_staging(&group, vec![ONE.to_string(), TWO.to_string()], STAGED_AT)
            .await
            .expect("a relay change is staged")
            .fanouts,
    );
    let due = ran(drive_due(
        &admin.circle,
        &accepting,
        &clock,
        Some(&group),
        None,
        &DriveMode::Full,
    )
    .await);
    assert!(
        due.driven
            .iter()
            .any(|(id, outcome)| *id == change && outcome.status == FanoutStatus::Confirmed)
            && admin.session().commit_removes_nobody_for_test(&group),
        "premise: a change that removes nobody was marked, and applied",
    );

    admin
        .session()
        .remove_members(&group, &[others[1].pubkey_hex()])
        .await
        .expect("a removal is staged, and no row written");
    let admin = admin.reopen();
    let repaired = the_one(rows_of(&admin, &group).await);
    assert!(
        !admin.session().commit_removes_nobody_for_test(&group),
        "a removal given its record at the open kept the mark of the change before it",
    );

    let unreachable = answering(&[(ONE, &[Answer::Unreachable]), (TWO, &[Answer::Unreachable])]);
    for days in [1, 3] {
        clock.set(days * 24 * HOUR_MS);
        let due = ran(drive_due(
            &admin.circle,
            &unreachable,
            &clock,
            Some(&group),
            None,
            &DriveMode::Full,
        )
        .await);
        assert!(
            due.driven
                .iter()
                .any(|(id, outcome)| *id == repaired && outcome.status == FanoutStatus::Unresolved),
            "a repaired removal was resolved with no relay's answer",
        );
    }
    assert!(staged_ref(&admin, &group).await.is_some());
}

// ── The pass before the open: the removal repair and the sweep of queued changes ──

async fn queued(member: &CircleMember, group: &GroupId) -> usize {
    member
        .session()
        .queued_intent_count_for_test(group)
        .await
        .expect("the queue is read")
}

/// A sweep of queued changes that fails does not stop the removal repair
/// that runs beside it, and says nothing false: the removal a kill left
/// staged is given its record at that open all the same, and the queued
/// change the sweep could not delete — still queued — is not told to its
/// circle as dropped. The next open, with the store writable, retires it and
/// says so.
#[tokio::test]
async fn a_sweep_that_fails_at_the_open_stops_no_repair_and_leaves_no_false_note() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let (db, key) = db_of(&admin);
    admin
        .session()
        .remove_members(&group, &[others[1].pubkey_hex()])
        .await
        .expect("a removal is staged, and no row written");
    // A different change, left queued by an answer that said "not made".
    admin
        .session()
        .queue_removal_intent_for_test(&group, &[others[0].pubkey_hex()])
        .await
        .expect("a change is left queued");
    assert!(rows_of(&admin, &group).await.is_empty(), "premise: no row");

    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true).expect("arm");
    let admin = admin.reopen();
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
        .expect("disarm");
    assert_eq!(
        rows_of(&admin, &group).await.len(),
        1,
        "a sweep that failed kept the staged removal from being given its record",
    );
    assert_eq!(queued(&admin, &group).await, 1, "premise: still queued");
    let said_dropped = |admin: &CircleMember| {
        admin
            .session()
            .peek_change_notes(&group)
            .iter()
            .any(|note| {
                matches!(
                    note,
                    ChangeNote::QueuedChangeDropped | ChangeNote::QueuedRemovalDropped
                )
            })
    };
    assert!(
        !said_dropped(&admin),
        "a change that is still queued was told to its circle as dropped",
    );

    let admin = admin.reopen();
    assert_eq!(queued(&admin, &group).await, 0);
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedRemovalDropped),
        "a removal retired unmade at the open was not said as one",
    );
}

/// The note the sweep writes ahead of a retirement is taken back when the
/// retirement fails — unless one may have stood before it. A store that
/// could not say whether one did is not read as "none did": the note an
/// earlier open wrote, truthfully, for a change it did drop is not cleared
/// by a later open that dropped nothing.
#[tokio::test]
async fn a_sweep_that_cannot_read_the_notes_takes_back_none_an_earlier_open_may_have_written() {
    let helpers::TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir,
        bob,
        bob_keys,
        bob_dir,
        group_id,
        ..
    } = helpers::setup_two_party_group("w9s_sweep_unreadable_notes").await;
    alice
        .queue_removal_intent_for_test(&group_id, &[bob_keys.public_key().to_hex()])
        .await
        .expect("a change is left queued");
    drop(alice);
    let notes = Arc::new(helpers::BalkyNotes::default());
    notes
        .untold
        .lock()
        .expect("notes")
        .push(ChangeNote::QueuedChangeDropped);
    notes.unreadable.store(true, Ordering::SeqCst);
    let db = StorageConfig::new(&alice_dir).database_path();
    let key = StorageConfig::test_sqlcipher_key().expect("test key");

    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true).expect("arm");
    let alice =
        SessionManager::new_unencrypted_with_notes(&alice_dir, &alice_keys, Some(notes.clone()))
            .expect("reopens");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
        .expect("disarm");
    assert_eq!(
        alice
            .queued_intent_count_for_test(&group_id)
            .await
            .expect("the queue is read"),
        1,
        "premise: the retirement failed and the change is still queued",
    );
    notes.unreadable.store(false, Ordering::SeqCst);
    assert!(
        alice
            .peek_change_notes(&group_id)
            .contains(&ChangeNote::QueuedChangeDropped),
        "a failed retirement behind an unreadable store cleared the note an earlier open \
         had written for a change it really dropped",
    );
    drop((alice, bob));
    helpers::cleanup_dir(&alice_dir);
    helpers::cleanup_dir(&bob_dir);
}

/// A queued removal whose own commit a kill left staged is that commit's
/// twin once the open has given the commit its record: it goes without a
/// word. The removal is being made, so its circle is not told it was
/// dropped.
#[tokio::test]
async fn a_queued_removal_whose_commit_is_given_its_record_at_the_open_is_not_told_as_dropped() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let leaving = [others[1].pubkey_hex()];
    admin
        .session()
        .remove_members(&group, &leaving)
        .await
        .expect("a removal is staged, and no row written");
    admin
        .session()
        .queue_removal_intent_for_test(&group, &leaving)
        .await
        .expect("the same removal is left queued");

    let admin = admin.reopen();
    assert_eq!(
        (
            rows_of(&admin, &group).await.len(),
            queued(&admin, &group).await
        ),
        (1, 0),
        "premise: the staged removal has its record, and its queued twin is gone",
    );
    assert!(
        !admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedChangeDropped),
        "a removal that is being made was told to its circle as dropped",
    );
}

/// A queued change whose own commit was already confirmed is that commit's
/// twin: the open retires it without a word. The change was made, so its
/// circle is not told it was dropped.
#[tokio::test]
async fn a_queued_change_whose_commit_was_confirmed_is_not_told_as_dropped() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let admins = [
        admin.keys.public_key().to_bytes(),
        others[0].keys.public_key().to_bytes(),
    ];
    let effects = admin
        .session()
        .update_admin_policy(&group, &admins)
        .await
        .expect("an admin change is staged");
    let (_, pending) = helpers::stranded::staged(&effects);
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the change is confirmed");
    admin
        .session()
        .queue_admin_policy_intent_for_test(
            &group,
            SessionManager::admin_policy_payload_for_test(&admins).expect("payload"),
        )
        .await
        .expect("the same change is left queued");
    assert_eq!(
        queued(&admin, &group).await,
        1,
        "premise: its twin is queued"
    );

    let admin = admin.reopen();
    let notes = admin.session().peek_change_notes(&group);
    assert!(
        queued(&admin, &group).await == 0
            && !notes.contains(&ChangeNote::QueuedChangeDropped)
            && !notes.contains(&ChangeNote::QueuedRemovalDropped),
        "the queued twin of a change that was made was kept, or told to its circle as \
         dropped",
    );
}

/// The copy of a removal already made is a new removal once its member has
/// been invited back: left queued at a kill, the open says it was set aside
/// and holds the circle for the member it names — never drops it as the twin
/// of the removal made before.
#[tokio::test]
async fn a_queued_removal_of_a_member_invited_back_is_told_and_held_not_dropped() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let member = &others[1];
    let named = [member.pubkey_hex()];
    let (_, pending) = helpers::stranded::staged(
        &admin
            .session()
            .remove_members(&group, &named)
            .await
            .expect("the member is removed"),
    );
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the removal is applied");
    let package =
        helpers::create_key_package_event(member.session(), &member.keys, &[ONE.to_string()]).await;
    let (_, pending) = helpers::stranded::staged(
        &admin
            .session()
            .add_members(
                &group,
                vec![SessionManager::key_package_from_event(&package).expect("it parses")],
            )
            .await
            .expect("the member is invited back"),
    );
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the invitation is applied");
    admin
        .session()
        .queue_removal_intent_for_test(&group, &named)
        .await
        .expect("a second removal is left queued");

    let admin = admin.reopen();
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let held: Vec<String> = rusqlite::Connection::open(
        admin
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .prepare("SELECT member FROM removal_targets WHERE gone_epoch IS NULL")
    .expect("the table exists")
    .query_map([], |row| row.get::<_, Vec<u8>>(0).map(hex::encode))
    .expect("read")
    .collect::<Result<_, _>>()
    .expect("read");
    assert!(
        queued(&admin, &group).await == 0
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped)
            && held == named,
        "a queued removal of a member invited back was dropped as the twin of the removal \
         made before, or its member is not held",
    );
}

/// A session opened with no store for its notes retires no queued change
/// at its open: the note is the only other trace of what the user asked
/// for, and one kept in memory dies with the process.
#[tokio::test]
async fn a_session_with_nowhere_to_keep_a_note_retires_no_queued_change_at_its_open() {
    let helpers::TwoPartyGroup {
        alice,
        alice_keys,
        alice_dir,
        bob,
        bob_keys,
        bob_dir,
        group_id,
        ..
    } = helpers::setup_two_party_group("w9hl_sweep_needs_a_note_store").await;
    alice
        .queue_removal_intent_for_test(&group_id, &[bob_keys.public_key().to_hex()])
        .await
        .expect("a change is left queued");
    drop(alice);

    let alice = SessionManager::new_unencrypted(&alice_dir, &alice_keys).expect("reopens");
    assert_eq!(
        alice
            .queued_intent_count_for_test(&group_id)
            .await
            .expect("the queue is read"),
        1,
        "a queued change was deleted behind a note that dies with the process",
    );
    drop((alice, bob));
    helpers::cleanup_dir(&alice_dir);
    helpers::cleanup_dir(&bob_dir);
}
