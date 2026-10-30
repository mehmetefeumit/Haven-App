//! When a durable fanout ends, and what a failed confirm leaves (Security
//! Rule 13).
//!
//! An applied commit's record keeps owing each frozen relay its attempt until
//! two distinct relays hold the commit or a day has passed since it was
//! staged, and is then deleted; only a commit still pending holds its circle's
//! next change. A pending commit no relay could ever be reached for is undone
//! through the engine after that day; one a relay may hold never is. A confirm
//! that returns an error is never a failed publish: the stored row says
//! whether the commit was applied.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted and
//! sends nothing, and every instant is read from a clock the test sets. The
//! only real time paid is the engine's own announced deadline where a test
//! shows a commit is NOT merged, or has a received commit applied
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

mod helpers;

use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::circle::{CircleConfig, CircleError, CircleManager};
use haven_core::nostr::mls::storage::{
    set_commit_retirement_fault_for_test, set_engine_write_fault_for_test,
    set_epoch_anchor_write_fault_for_test, set_fanout_write_fault_naming_for_test,
    set_stored_message_write_fault_for_test, set_stored_message_write_fault_sparing_for_test,
    EngineWrite,
};
use haven_core::nostr::mls::types::{
    EpochState, FanoutId, FanoutMls, FanoutProbe, FanoutTargetStatus, GroupId, MessageId,
    MessageState, OpenMlsContentKind, PendingStateRef, PublishWork, ScreenedIngest, SessionEffects,
    TransportMessage,
};
use haven_core::nostr::mls::{ChangeNote, CommitNotes as _, SessionManager, StorageConfig};
use haven_core::nostr::NostrError;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    drive_due, drive_one, is_owned, wake_unreachable, DriveMode, DriveOutcome, FanoutClock,
    FanoutSend, FanoutStatus, FanoutTargetOutcome, Taken, BUSY_RETRY_MS, GATE_WAIT_SECS,
    MDK_CALL_CEILING_SECS, ROW_BUDGET_MS,
};
use helpers::{
    assert_no_needles, capture_haven_log, setup_circle, BalkyNotes, CircleFixture, CircleMember,
    LogLine,
};

const ONE: &str = "wss://one.end-canary9b2d.example.com";
const TWO: &str = "wss://two.end-canary9b2d.example.com";
const THREE: &str = "wss://three.end-canary9b2d.example.com";
const CANARY: &str = "end-canary9b2d";

const SECOND_MS: u64 = 1_000;
const HOUR_MS: u64 = 3_600 * SECOND_MS;
const DAY_MS: u64 = 24 * HOUR_MS;
const STAGED_AT: u64 = 1_700_000_000_000;

/// A clock a test sets, read as an offset from the instant every commit in
/// this file is staged at.
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

fn answering(answers: &[(&str, &[Answer])]) -> ScriptedFanout {
    let transport = ScriptedFanout::default();
    for (target, script) in answers {
        transport.answer(target, script.iter().copied());
    }
    transport
}

fn the_one(ids: Vec<FanoutId>) -> FanoutId {
    let [id] = <[FanoutId; 1]>::try_from(ids).unwrap_or_else(|_| panic!("exactly one fanout row"));
    id
}

/// Stages the removal of `fx`'s last member in staging mode.
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
    use haven_core::nostr::mls::types::ConvergedRoster;
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

/// What a test changes in a CLOSED MLS database, written as the storage
/// backend itself writes it, to leave the store the way a rival branch
/// winning, or a process killed inside one of the engine's own multi-write
/// steps, leaves it.
#[derive(Clone, Copy)]
enum StoreEdit<'a> {
    /// Gives the stored message `id` names the state `state`.
    MessageState { id: &'a [u8], state: MessageState },
    /// Forgets the intent the engine keeps beside the own commit `commit`
    /// names: a removal's is written after its staging returns.
    ForgetOwnCommitIntent { commit: &'a [u8] },
    /// Takes the group record's epoch back by one: an eviction's staging
    /// moves it forward after it has stored the commit.
    RewindRecordEpoch { group: &'a GroupId },
    /// Sets every exposure flag of every stored fanout record, leaving each
    /// target's status as it is: a record another version wrote.
    FlagEveryFanoutExposed,
}

/// Applies `edit` through a second storage handle. Only ever on a closed
/// database (Rule 14): a live session holds its own in-memory state.
fn edit_closed_store_for_test(
    db: &std::path::Path,
    key: &storage_sqlite::SqlCipherKey,
    edit: StoreEdit<'_>,
) -> Result<(), ()> {
    use cgka_traits::storage::{
        GroupStorage, MessageStorage, OutboundFanoutStorage, OutboundIntentStorage,
    };

    haven_core::sqlcipher_init::ensure().map_err(|_| ())?;
    let store = storage_sqlite::SqliteAccountStorage::open_encrypted_with_options(
        db,
        key,
        StorageConfig::storage_options(),
    )
    .map_err(|_| ())?;
    match edit {
        StoreEdit::MessageState { id, state } => {
            store.update_message_state(&MessageId::new(id.to_vec()), state)
        }
        StoreEdit::ForgetOwnCommitIntent { commit } => {
            store.delete_own_commit_intent(&MessageId::new(commit.to_vec()))
        }
        StoreEdit::RewindRecordEpoch { group } => store.get_group(group).and_then(|mut record| {
            record.epoch = haven_core::nostr::mls::types::EpochId(record.epoch.0.saturating_sub(1));
            store.put_group(&record)
        }),
        StoreEdit::FlagEveryFanoutExposed => store.list_outbound_fanouts().and_then(|rows| {
            for row in rows {
                let mut record = serde_json::to_value(&row).map_err(|_| ()).ok();
                let flags = row.target_statuses().len();
                if let Some(record) = record.as_mut() {
                    record["target_possible_exposure"] = serde_json::json!(vec![true; flags]);
                }
                let flagged = record
                    .and_then(|record| serde_json::from_value(record).ok())
                    .unwrap_or(row);
                store.put_outbound_fanout(&flagged)?;
            }
            Ok(())
        }),
    }
    .map_err(|_| ())
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

/// A location `sender` seals for `group` now.
async fn location_from(sender: &CircleMember, group: &GroupId) -> Option<nostr::Event> {
    sender
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await
        .ok()
        .map(|sealed| sealed.0)
}

/// A location sealed through the driver in the full mode, no relay taken:
/// the mode whose send runs the engine's own preflight.
async fn full_location_from(sender: &CircleMember, group: &GroupId) -> Option<nostr::Event> {
    use haven_core::relay::fanout::{scripted::Inert, LocationSeal, Publishing, WallClock};
    let publishing: Publishing<'_, Inert> = Publishing {
        fanout: &Inert,
        publisher: &Inert,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    match publishing
        .seal_location(
            &sender.circle,
            group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await
        .ok()?
        .seal
    {
        LocationSeal::Sealed { event, .. } => Some(*event),
        LocationSeal::Deferred(_) => None,
    }
}

async fn can_send(member: &CircleMember, group: &GroupId) -> bool {
    location_from(member, group).await.is_some()
}

/// A second circle of `member`'s own, alone in it, on `relays`.
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

/// Stages a relay change in `group`: a commit frozen for the relays the
/// circle has now.
async fn stage_relay_change(member: &CircleMember, group: &GroupId, to: &[&str]) -> FanoutId {
    the_one(
        member
            .session()
            .update_relays_staging(
                group,
                to.iter().map(ToString::to_string).collect(),
                STAGED_AT,
            )
            .await
            .expect("a relay change is staged")
            .fanouts,
    )
}

/// Stages a relay change in `group` with no record, as a kill between the
/// stage and its record's write leaves one, so that the next open leaves the
/// commit to the engine: hydrate clears it and announces the clear, for
/// whatever call takes the open's batch first.
async fn stage_a_commit_the_next_open_clears(member: &CircleMember, group: &GroupId, to: &str) {
    member
        .session()
        .update_relays(group, vec![to.to_string()])
        .await
        .expect("a relay change is staged, and no row written");
}

fn split(fx: CircleFixture) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let mut members = fx.members;
    let admin = members.remove(0);
    (admin, members, fx.group)
}

async fn drive(
    member: &CircleMember,
    transport: &ScriptedFanout,
    clock: &Clock,
    id: &FanoutId,
) -> DriveOutcome {
    drive_one(&member.circle, transport, clock, id, &DriveMode::Full)
        .await
        .expect("the drive runs")
}

/// How many of `calls` went to `target` carrying `event`.
fn calls_to(
    calls: &[haven_core::relay::fanout::scripted::Call],
    target: &str,
    event: nostr::EventId,
) -> usize {
    calls
        .iter()
        .filter(|call| call.target == target && call.event_id == event)
        .count()
}

/// How many peer locations a drive handed back.
fn locations(outcome: &DriveOutcome) -> usize {
    use haven_core::nostr::mls::types::LocationMessageResult;
    outcome
        .replayed
        .results
        .iter()
        .filter(|result| matches!(result, LocationMessageResult::Location { .. }))
        .count()
}

fn line_saying<'a>(lines: &'a [LogLine], words: &str) -> &'a LogLine {
    lines
        .iter()
        .find(|line| line.message.contains(words))
        .unwrap_or_else(|| panic!("no log line says: {words}"))
}

// ── An applied commit's record: an obligation, never a hold ──────────────────

/// One acknowledgement applies the commit. The second is something the device
/// still owes — retried — and never something the circle waits for: it sends,
/// and takes its next change, while a relay of the first is still silent.
/// When a second relay does take the commit the record ends, and the third is
/// asked no more.
#[tokio::test]
async fn second_ack_is_retry_obligation_not_hold() {
    let fx = setup_circle(3, &[ONE, TWO, THREE]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let frozen = row(admin, &id).await;
    assert_eq!(frozen.required_acks, 2);
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Silent]),
        (THREE, &[Answer::Unreachable]),
    ]);
    let clock = Clock::at(0);

    let outcome = drive(admin, &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && settled_members(admin, &fx.group).await == Some(2),
        "one acknowledgement did not apply the commit",
    );
    let kept = row(admin, &id).await;
    assert_eq!(kept.mls, FanoutMls::Confirmed);
    let status_of = |relay: &str| {
        kept.statuses[kept
            .targets
            .iter()
            .position(|target| target == relay)
            .expect("a frozen relay")]
    };
    assert_eq!(
        [status_of(ONE), status_of(TWO), status_of(THREE)],
        [
            FanoutTargetStatus::Accepted,
            FanoutTargetStatus::PossiblyExposed,
            FanoutTargetStatus::RetryableUnavailable,
        ],
        "the relays that have not taken the commit are no longer owed it",
    );
    assert!(outcome.retry_after_ms.is_some());
    transport.calls();

    // Not a hold: the circle sends, and takes and applies its next change —
    // which every relay takes, so that nothing but the first commit's record
    // is waiting on a relay afterwards.
    assert!(can_send(admin, &fx.group).await);
    let next = stage_relay_change(admin, &fx.group, &[ONE, TWO]).await;
    let taking = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Accepted]),
        (THREE, &[Answer::Accepted]),
    ]);
    clock.set(60 * SECOND_MS);
    assert_eq!(
        drive(admin, &taking, &clock, &next).await.status,
        FanoutStatus::Confirmed,
        "an applied commit still owed to a relay held its circle's next change",
    );
    assert_eq!(row(admin, &id).await.mls, FanoutMls::Confirmed);

    // The second relay takes it: the obligation is met and the record ends.
    transport.answer(TWO, [Answer::Accepted]);
    clock.set(HOUR_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    let retried = transport.calls();
    assert_eq!(calls_to(&retried, TWO, frozen.event_id), 1);
    assert!(
        retried.iter().all(|call| call.payload == frozen.payload),
        "what was sent again is not the frozen event",
    );
    assert!(probe(admin, &id).await.is_none());
    clock.set(5 * HOUR_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Gone
    );
    assert_eq!(
        calls_to(&transport.calls(), THREE, frozen.event_id),
        0,
        "a relay was asked again for a commit whose record had ended",
    );
}

/// An applied commit's record ends, and ending is a delete: at once when two
/// relays hold the commit, and otherwise a day after it was staged — not a
/// millisecond earlier — after which its failing relay is never called again
/// and its event is no longer the driver's alone.
#[tokio::test]
async fn post_confirm_fanout_terminates_and_its_row_is_deleted() {
    // Two relays hold it: ended in the drive that confirmed it.
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let event = row(fx.admin(), &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let outcome = drive(fx.admin(), &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert!(outcome.retry_after_ms.is_none());
    assert!(probe(fx.admin(), &id).await.is_none() && !is_owned(&event));
    transport.calls();
    assert_eq!(
        drive(fx.admin(), &transport, &clock, &id).await.status,
        FanoutStatus::Gone
    );
    assert_eq!(transport.calls().len(), 0);

    // One relay holds it and the other cannot be reached: retried, until the
    // bound.
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let event = row(fx.admin(), &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Unreachable])]);
    let clock = Clock::at(0);
    let outcome = drive(fx.admin(), &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert!(
        outcome.retry_after_ms.is_some_and(|wait| wait <= DAY_MS),
        "a record that will end at its bound did not say so",
    );
    clock.set(DAY_MS - 1);
    let outcome = drive(fx.admin(), &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert!(
        probe(fx.admin(), &id).await.is_some() && is_owned(&event),
        "a record ended before its bound with a relay still owed the commit",
    );
    assert_eq!(
        outcome.retry_after_ms,
        Some(1),
        "the relay just called is not due for seconds, and the bound is a \
         millisecond away: the record's next wake is the bound",
    );
    assert_eq!(
        calls_to(&transport.calls(), TWO, event),
        2,
        "premise: the failing relay was retried before the bound",
    );

    clock.set(DAY_MS);
    assert_eq!(
        drive(fx.admin(), &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert!(
        probe(fx.admin(), &id).await.is_none() && !is_owned(&event),
        "a record outlived its bound",
    );
    transport.calls();
    for hours in [25, 30, 24 * 9] {
        clock.set(hours * HOUR_MS);
        assert_eq!(
            drive(fx.admin(), &transport, &clock, &id).await.status,
            FanoutStatus::Gone
        );
    }
    assert_eq!(
        transport.calls().len(),
        0,
        "a relay was called for a record that had ended",
    );
    assert_eq!(settled_members(fx.admin(), &fx.group).await, Some(1));
}

/// A relay that is gone for good never blocks a circle: the commit it never
/// took is applied on the other relay's word, and the circle's next commit is
/// staged, sent and applied while the first is still owed to the dead one.
#[tokio::test]
async fn a_dead_relay_after_confirm_never_blocks_the_next_commit() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Unreachable])]);
    let clock = Clock::at(0);

    let first = stage_removal(&fx).await;
    assert_eq!(
        drive(admin, &transport, &clock, &first).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(row(admin, &first).await.mls, FanoutMls::Confirmed);
    assert_eq!(settled_members(admin, &fx.group).await, Some(2));

    clock.set(SECOND_MS);
    let other = fx.members[1].pubkey_hex();
    let second = the_one(
        admin
            .session()
            .remove_members_staging(&fx.group, &[other], STAGED_AT + SECOND_MS)
            .await
            .expect("the next change is staged beside an applied commit's record")
            .fanouts,
    );
    assert_eq!(
        drive(admin, &transport, &clock, &second).await.status,
        FanoutStatus::Confirmed,
        "a dead relay held the circle's next commit",
    );
    assert_eq!(settled_members(admin, &fx.group).await, Some(1));
    assert!(can_send(admin, &fx.group).await);
    assert_eq!(
        row(admin, &first).await.statuses,
        [
            FanoutTargetStatus::Accepted,
            FanoutTargetStatus::RetryableUnavailable
        ],
        "the first commit is no longer owed to the relay that never took it",
    );
}

// ── A pending commit's record ────────────────────────────────────────────────

/// Neither end touches a commit that is still pending: with one relay that
/// may hold it, no number of days ends a target, deletes the row or lets go
/// of the commit. Its relays are asked again for as long as it takes.
#[tokio::test]
async fn no_target_is_policy_terminated_while_pending() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Unreachable])]);
    let clock = Clock::at(0);
    for hours in [0, 24, 48, 24 * 30] {
        clock.set(hours * HOUR_MS);
        let outcome = drive(admin, &transport, &clock, &id).await;
        assert_eq!(outcome.status, FanoutStatus::Unresolved);
        let stored = row(admin, &id).await;
        assert_eq!(stored.mls, FanoutMls::Pending);
        assert_eq!(
            stored.statuses,
            [
                FanoutTargetStatus::PossiblyExposed,
                FanoutTargetStatus::RetryableUnavailable
            ],
            "a pending commit's target was ended by a bound ({hours} h)",
        );
        assert_eq!(
            transport.calls().len(),
            2,
            "a pending commit's relays were no longer asked ({hours} h)",
        );
    }
    assert!(
        staged_ref(admin, &fx.group).await.is_some()
            && commit_state(admin, event).await == Some(MessageState::Sent)
            && is_owned(&event),
    );
}

/// A commit one relay may hold is never undone by the bound, whatever every
/// relay says afterwards and however long: the acknowledgement that finally
/// arrives applies it. The commit here removes nobody, so the bound is the
/// only thing between it and a rollback.
#[tokio::test]
async fn a_possibly_exposed_pending_commit_is_never_bounded() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let before = admin.session().epoch(&fx.group).await.expect("epoch");
    let id = stage_relay_change(admin, &fx.group, &[ONE, THREE]).await;
    let frozen = row(admin, &id).await;
    // The first call's answer never came; every later one cannot be reached.
    let transport = answering(&[
        (ONE, &[Answer::Silent, Answer::Unreachable]),
        (TWO, &[Answer::Unreachable]),
    ]);
    let clock = Clock::at(0);
    for hours in [0, 24, 25, 24 * 30] {
        clock.set(hours * HOUR_MS);
        let mut status = None;
        let lines = capture_haven_log(async {
            status = Some(drive(admin, &transport, &clock, &id).await.status);
        })
        .await;
        assert_eq!(
            status,
            Some(FanoutStatus::Unresolved),
            "a commit a relay may hold was resolved without an acknowledgement ({hours} h)",
        );
        assert_eq!(
            row(admin, &id).await.statuses,
            [
                FanoutTargetStatus::PossiblyExposed,
                FanoutTargetStatus::RetryableUnavailable
            ],
            "the bound ended a target of a commit a relay may hold ({hours} h)",
        );
        assert!(
            lines
                .iter()
                .all(|line| !line.message.contains("was undone")),
            "a commit a relay may hold was said to be undone ({hours} h)",
        );
    }
    assert!(
        staged_ref(admin, &fx.group).await.is_some()
            && commit_state(admin, frozen.event_id).await == Some(MessageState::Sent)
            && row(admin, &id).await.mls == FanoutMls::Pending,
        "a commit a relay may hold was undone at the bound",
    );
    transport.calls();

    transport.answer(ONE, [Answer::Accepted]);
    clock.set(24 * 31 * HOUR_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert!(transport
        .calls()
        .iter()
        .all(|call| call.event_id == frozen.event_id && call.payload == frozen.payload));
    assert!(staged_ref(admin, &fx.group).await.is_none());
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before + 1
    );
}

/// A call Haven could not make is not its relay's answer. When another send
/// holds a relay for the whole of the transport's wait, nothing is handed
/// over and the relay has said nothing: an applied commit's record does not
/// end on the count of the others while that relay has never been called,
/// and a pending commit is not undone, however old, as one no relay could be
/// reached for. Each is settled by the first call that is really made.
#[tokio::test]
async fn a_relay_that_was_only_ever_busy_is_still_owed_its_call_and_undoes_nothing() {
    // Applied: two relays take the commit, the third is never called.
    let fx = setup_circle(3, &[ONE, TWO, THREE]).await;
    let admin = fx.admin();
    let id = stage_relay_change(admin, &fx.group, &[ONE, TWO]).await;
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Accepted]),
        (THREE, &[Answer::Busy]),
    ]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert!(
        probe(admin, &id).await.is_some(),
        "a record ended on two acknowledgements with a frozen relay never called",
    );
    transport.answer(THREE, [Answer::Unreachable]);
    clock.set(6 * SECOND_MS);
    let _ = drive(admin, &transport, &clock, &id).await;
    assert!(
        probe(admin, &id).await.is_none(),
        "premise: the record ends once its last relay has answered a real call",
    );

    // Pending, and removing nobody: a day of calls that were never made
    // undoes nothing; the first real "could not be reached" after it does.
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_relay_change(admin, &fx.group, &[ONE, THREE]).await;
    let transport = answering(&[(ONE, &[Answer::Busy]), (TWO, &[Answer::Busy])]);
    for at in [0, DAY_MS, DAY_MS + HOUR_MS] {
        clock.set(at);
        let outcome = drive(admin, &transport, &clock, &id).await;
        assert_eq!(outcome.status, FanoutStatus::Unresolved);
        assert!(
            outcome.notes.is_empty() && staged_ref(admin, &fx.group).await.is_some(),
            "a commit was undone at its bound though no relay had been called",
        );
    }
    for relay in [ONE, TWO] {
        transport.answer(relay, [Answer::Unreachable]);
    }
    clock.set(DAY_MS + HOUR_MS + 6 * SECOND_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::RolledBack,
        "premise: once each relay was really asked and could not be reached, the bound applies",
    );
}

/// A relay another send holds is not attempted at all: no attempt is begun
/// for it, so nothing is counted against it. However many times that
/// happens, the first call that is really made and fails waits as that
/// relay's FIRST failure — five seconds when it could not be reached, thirty
/// when it answered nothing — and the commit is asked to be driven again
/// five seconds after each round that never reached it.
#[tokio::test]
async fn a_call_that_was_never_made_is_no_attempt_and_lengthens_no_wait() {
    for (real, first_wait_ms) in [
        (Answer::Unreachable, 5 * SECOND_MS),
        (Answer::Silent, 30 * SECOND_MS),
    ] {
        let fx = setup_circle(3, &[ONE]).await;
        let admin = fx.admin();
        let id = stage_removal(&fx).await;
        let transport = answering(&[(ONE, &[Answer::Busy])]);
        let clock = Clock::at(0);
        for round in 0..6 {
            clock.set(round * BUSY_RETRY_MS);
            let outcome = drive(admin, &transport, &clock, &id).await;
            assert_eq!(outcome.status, FanoutStatus::Unresolved);
            assert_eq!(
                outcome.retry_after_ms,
                Some(BUSY_RETRY_MS),
                "a commit whose relay was held by another send did not ask to be driven \
                 again five seconds later",
            );
        }
        let stored = row(admin, &id).await;
        assert_eq!(
            (stored.statuses, stored.attempts),
            (vec![FanoutTargetStatus::NotAttempted], vec![0]),
            "a call that was never made was stored as an attempt",
        );
        assert!(transport.calls().is_empty());

        transport.answer(ONE, [real]);
        let began = 6 * BUSY_RETRY_MS;
        clock.set(began);
        let outcome = drive(admin, &transport, &clock, &id).await;
        assert_eq!(transport.calls().len(), 1, "premise: the relay is called");
        assert_eq!(
            outcome.retry_after_ms,
            Some(first_wait_ms),
            "the relay's first real failure waited as if the calls never made had failed",
        );
        clock.set(began + first_wait_ms - 1);
        let _ = drive(admin, &transport, &clock, &id).await;
        assert!(
            transport.calls().is_empty(),
            "called before its wait was over"
        );
        clock.set(began + first_wait_ms);
        let _ = drive(admin, &transport, &clock, &id).await;
        assert_eq!(
            transport.calls().len(),
            1,
            "not called when its wait was over"
        );
    }
}

/// The bound is asked only once a drive has tried what was due. A commit no
/// relay could be reached for, found past its day by a drive in which another
/// send holds its relay, is not undone in that drive: the relay is owed one
/// more try first — a device that slept through the day must not undo a
/// change the moment it wakes — and the commit the relay then takes is
/// applied.
#[tokio::test]
async fn a_commit_past_its_bound_is_not_undone_in_a_drive_that_could_not_have_its_relay() {
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let id = stage_relay_change(admin, &fx.group, &[ONE, TWO]).await;
    let transport = answering(&[(ONE, &[Answer::Unreachable, Answer::Busy, Answer::Accepted])]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Unresolved
    );
    assert_eq!(
        row(admin, &id).await.statuses,
        [FanoutTargetStatus::RetryableUnavailable],
        "premise: the relay really could not be reached",
    );

    clock.set(DAY_MS + HOUR_MS);
    let outcome = drive(admin, &transport, &clock, &id).await;
    assert_eq!(
        outcome.status,
        FanoutStatus::Unresolved,
        "a commit was undone at its bound by a drive that never got to try its relay",
    );
    assert!(outcome.notes.is_empty() && staged_ref(admin, &fx.group).await.is_some());
    assert_eq!(outcome.retry_after_ms, Some(BUSY_RETRY_MS));

    clock.set(DAY_MS + HOUR_MS + BUSY_RETRY_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed,
        "the relay, once it could be had, was not asked",
    );
}

/// The same when what has the relay is ANOTHER record's call: two drives
/// overlap, one circle's commit is on its way to the relay, and the drive of
/// a second circle's commit — past its day, never reached — finds that relay
/// taken. The relay is owed to this record and was not tried, so the bound
/// is not asked: the commit is not undone, and is applied once the relay is
/// free and takes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_past_its_bound_is_not_undone_while_another_records_call_has_its_relay() {
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let relays = vec![ONE.to_string()];
    let other = admin
        .circle
        .create_circle(
            &admin.keys,
            Vec::new(),
            &CircleConfig::new("Other").with_relays(relays.clone()),
        )
        .await
        .expect("a second circle on the same relay")
        .circle
        .mls_group_id;
    let waiting = stage_relay_change(admin, &fx.group, &[ONE, TWO]).await;
    let transport = answering(&[(ONE, &[Answer::Unreachable, Answer::Accepted])]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(admin, &transport, &clock, &waiting).await.status,
        FanoutStatus::Unresolved,
        "premise: the relay could not be reached",
    );

    // A day later the other circle's commit is on its way to that relay.
    clock.set(DAY_MS + HOUR_MS);
    let calling = stage_relay_change(admin, &other, &[ONE, THREE]).await;
    transport.park();
    let in_flight = drive(admin, &transport, &clock, &calling);
    tokio::pin!(in_flight);
    tokio::select! {
        biased;
        _ = &mut in_flight => panic!("the drive finished while its call was parked"),
        () = transport.parked() => {}
    }

    let outcome = drive(admin, &transport, &clock, &waiting).await;
    assert_eq!(
        outcome.status,
        FanoutStatus::Unresolved,
        "a commit was undone at its bound by a drive whose relay another record's call had",
    );
    assert!(outcome.notes.is_empty() && staged_ref(admin, &fx.group).await.is_some());
    assert_eq!(outcome.retry_after_ms, Some(BUSY_RETRY_MS));
    assert_eq!(
        row(admin, &waiting).await.attempts,
        [1],
        "a relay taken by another record's call was counted as tried",
    );

    transport.unpark();
    assert_eq!(in_flight.await.status, FanoutStatus::Confirmed);
    clock.set(DAY_MS + HOUR_MS + BUSY_RETRY_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &waiting).await.status,
        FanoutStatus::Confirmed,
        "the relay, once it was free, was not asked",
    );
}

/// A change no relay could be reached for does not hold its circle for ever.
/// A day after it was staged — and not before — with nothing ever possibly
/// exposed, it is undone THROUGH THE ENGINE: the staged commit is discarded,
/// its own row retired so no convergence pass merges it, the record deleted,
/// and the circle takes the same change again at once.
#[tokio::test]
async fn a_never_exposed_pending_commit_is_rolled_back_through_the_engine_after_the_bound() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let before = admin.session().epoch(&fx.group).await.expect("epoch");
    let id = stage_relay_change(admin, &fx.group, &[ONE, THREE]).await;
    let event = row(admin, &id).await.event_id;
    // One relay cannot be reached; the other answers every attempt "not now".
    let transport = answering(&[(ONE, &[Answer::Unreachable]), (TWO, &[Answer::RateLimited])]);
    let clock = Clock::at(0);
    for at in [0, 12 * HOUR_MS, DAY_MS - 1] {
        clock.set(at);
        assert_eq!(
            drive(admin, &transport, &clock, &id).await.status,
            FanoutStatus::Unresolved
        );
    }
    assert!(
        staged_ref(admin, &fx.group).await.is_some()
            && row(admin, &id).await.mls == FanoutMls::Pending,
        "a change was undone before its bound",
    );

    clock.set(DAY_MS);
    let mut outcome = None;
    let lines = capture_haven_log(async {
        outcome = Some(drive(admin, &transport, &clock, &id).await);
    })
    .await;
    let outcome = outcome.expect("ran");
    assert_eq!(outcome.status, FanoutStatus::RolledBack);
    assert_eq!(
        outcome.notes,
        [ChangeNote::ChangeUndone],
        "a change undone at its bound was not said to be",
    );
    assert_eq!(
        admin.session().take_change_notes(&fx.group),
        [ChangeNote::ChangeUndone],
        "what a drive nobody may be waiting on undid was not kept to be read",
    );
    assert!(
        admin.session().take_change_notes(&fx.group).is_empty(),
        "a note was handed over twice",
    );
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && admin
                .session()
                .group_relays(&fx.group)
                .await
                .expect("relays")
                == [ONE, TWO],
        "the engine still holds, or applied, a change no relay took",
    );
    assert_eq!(
        commit_state(admin, event).await,
        Some(MessageState::Failed),
        "the undone commit's row was not retired",
    );
    assert!(probe(admin, &id).await.is_none() && !is_owned(&event));
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "within its bound was undone")),
        &[
            &hex::encode(fx.group.as_slice()),
            &event.to_hex(),
            &admin.pubkey_hex(),
            CANARY,
        ],
    );
    serve_deadlines(admin, &fx.group).await;
    assert_eq!(
        admin.session().epoch(&fx.group).await.expect("epoch"),
        before,
        "a commit no relay was reached for was merged after it was undone",
    );

    // The circle is usable again: the same change, staged anew, applies.
    let again = stage_relay_change(admin, &fx.group, &[ONE, THREE]).await;
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(DAY_MS + 2 * HOUR_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &again).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        admin
            .session()
            .group_relays(&fx.group)
            .await
            .expect("relays"),
        [ONE, THREE]
    );
}

// ── Every frozen relay gets its attempt ──────────────────────────────────────

/// A commit of `admin`'s own second circle on `relays`, whose every relay is
/// failing as `transport` scripts: what leaves those relays backing off.
async fn failing_elsewhere(
    admin: &CircleMember,
    relays: &[&str],
    transport: &ScriptedFanout,
    clock: &Clock,
) -> FanoutId {
    let group = solo_circle(admin, relays).await;
    let id = stage_relay_change(admin, &group, &relays[..1]).await;
    assert_eq!(
        drive(admin, transport, clock, &id).await.status,
        FanoutStatus::Unresolved
    );
    id
}

/// The first acknowledgement applies the commit; the relays that were not
/// free to be asked then are still owed it, across a restart, and each is
/// sent the frozen event exactly once before the record ends.
#[tokio::test]
async fn every_snapshotted_relay_attempted_after_first_ack_across_restart() {
    let fx = setup_circle(3, &[ONE, TWO, THREE]).await;
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Unreachable]),
        (THREE, &[Answer::Unreachable]),
    ]);
    let clock = Clock::at(0);
    // Another circle's commit has just failed to reach two of the relays.
    failing_elsewhere(fx.admin(), &[TWO, THREE], &transport, &clock).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    transport.calls();

    clock.set(SECOND_MS);
    assert_eq!(
        drive(fx.admin(), &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        row(fx.admin(), &id).await.statuses,
        [
            FanoutTargetStatus::Accepted,
            FanoutTargetStatus::NotAttempted,
            FanoutTargetStatus::NotAttempted,
        ],
        "premise: two frozen relays were backing off when the commit was confirmed",
    );
    assert_eq!(transport.calls().len(), 1);

    // The process dies; the next one still owes both.
    let (admin, _others, group) = split(fx);
    let admin = admin.reopen();
    assert_eq!(
        row(&admin, &id).await.statuses[1..],
        [FanoutTargetStatus::NotAttempted; 2]
    );
    transport.answer(TWO, [Answer::Accepted]);
    transport.answer(THREE, [Answer::Accepted]);
    clock.set(10 * SECOND_MS);
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
    assert_eq!(
        due.driven[0].0, id,
        "a relay's next call went to a commit it had been sent before one it had not",
    );
    let sent = transport.calls();
    for relay in [TWO, THREE] {
        assert_eq!(
            calls_to(&sent, relay, frozen.event_id),
            1,
            "a frozen relay was not sent the commit after the restart, or was sent it twice",
        );
    }
    assert!(sent
        .iter()
        .filter(|call| call.event_id == frozen.event_id)
        .all(|call| call.payload == frozen.payload));
    // Every relay holds it. The record is kept for that one pass, as what
    // showed the other circle's commit that the relays were back, and goes
    // at its next drive without another call.
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
    assert_eq!(calls_to(&transport.calls(), TWO, frozen.event_id), 0);
    assert!(probe(&admin, &id).await.is_none());
    assert_eq!(settled_members(&admin, &group).await, Some(2));
}

/// The bound ends retries, never a first attempt: a record past its day with
/// a relay it has not yet been free to ask is kept until that relay has been
/// asked once, and only then deleted.
#[tokio::test]
async fn a_fanout_past_its_bound_still_attempts_a_never_attempted_target_before_deletion() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let admin = fx.admin();
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Unreachable]),
        (THREE, &[Answer::Silent]),
    ]);
    let clock = Clock::at(0);
    // Another circle's commit, which a relay may hold and so never ends,
    // keeps failing to reach the second relay.
    let elsewhere = failing_elsewhere(admin, &[TWO, THREE], &transport, &clock).await;
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    clock.set(SECOND_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        row(admin, &id).await.statuses,
        [
            FanoutTargetStatus::Accepted,
            FanoutTargetStatus::NotAttempted
        ],
    );

    // Past the bound, with the relay just failed for the other circle again.
    clock.set(DAY_MS);
    let _ = drive(admin, &transport, &clock, &elsewhere).await;
    transport.calls();
    clock.set(DAY_MS + SECOND_MS);
    let outcome = drive(admin, &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert_eq!(transport.calls().len(), 0, "premise: the relay is not due");
    assert_eq!(
        row(admin, &id).await.statuses[1],
        FanoutTargetStatus::NotAttempted,
        "a record past its bound was ended with a relay it had never asked",
    );
    assert!(outcome.retry_after_ms.is_some());

    clock.set(DAY_MS + 10 * SECOND_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        calls_to(&transport.calls(), TWO, event),
        1,
        "the relay was not asked once before the record ended",
    );
    // Ended: no further call is ever made under it. The other circle's
    // commit still owes that relay, so the record itself is kept, inert,
    // rather than start the relay's schedule over by leaving.
    for hours in [1, 5, 30] {
        clock.set(DAY_MS + hours * HOUR_MS);
        assert_eq!(
            drive(admin, &transport, &clock, &id).await.status,
            FanoutStatus::Confirmed
        );
    }
    assert_eq!(
        transport.calls().len(),
        0,
        "a relay was called for a record past its bound that had asked every relay",
    );
    assert!(probe(admin, &id).await.is_some());

    // And deleted once its going changes no relay's wait: both relays take
    // the other circle's commit, and nothing is left that waits on them.
    for relay in [TWO, THREE] {
        transport.answer(relay, [Answer::Accepted]);
    }
    clock.set(DAY_MS + 32 * HOUR_MS);
    assert_eq!(
        drive(admin, &transport, &clock, &elsewhere).await.status,
        FanoutStatus::Confirmed
    );
    transport.calls();
    let _ = drive(admin, &transport, &clock, &id).await;
    assert_eq!(transport.calls().len(), 0);
    assert!(
        probe(admin, &id).await.is_none(),
        "a record that had ended outlived every wait its going could change",
    );
}

/// An attempt whose call never returned has not run to an answer. Past its
/// bound the record waits for that relay to be asked once more — on the
/// schedule of a relay that may hold the event, not at once — and ends when
/// it has answered.
#[tokio::test]
async fn an_attempt_that_never_returned_is_run_to_an_answer_before_its_record_ends() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let (admin, _others, _group) = split(fx);
    let event = row(&admin, &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );

    // Twenty seconds before the bound a drive calls the silent relay again,
    // and the process dies with that call under way.
    clock.set(DAY_MS - 20 * SECOND_MS);
    transport.park();
    {
        let driving = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full);
        tokio::pin!(driving);
        tokio::select! {
            biased;
            _ = &mut driving => panic!("the drive finished while its call was parked"),
            () = transport.parked() => {}
        }
    }
    transport.unpark();
    let admin = admin.reopen();
    assert_eq!(
        row(&admin, &id).await.statuses[1],
        FanoutTargetStatus::Attempting
    );
    transport.calls();

    // Past the bound, and not yet a minute after the interrupted call.
    clock.set(DAY_MS + SECOND_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        transport.calls().len(),
        0,
        "an interrupted call was repeated at once"
    );
    assert_eq!(
        row(&admin, &id).await.statuses[1],
        FanoutTargetStatus::PossiblyExposed,
        "a record past its bound was ended on an attempt that never returned",
    );

    clock.set(DAY_MS + 41 * SECOND_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(calls_to(&transport.calls(), TWO, event), 1);
    assert!(probe(&admin, &id).await.is_none());
}

/// A commit that later loses to a rival branch still owes each frozen relay
/// its attempt: an applied commit's record is driven without its commit's
/// stored state being read. The relay it had not been free to ask is sent the
/// frozen event once, the record then ends by the same rules, and nothing is
/// rolled back or retired on the way.
#[tokio::test]
async fn a_confirmed_commit_that_later_loses_still_gives_every_frozen_relay_its_attempt() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Unreachable]),
        (THREE, &[Answer::Silent]),
    ]);
    let clock = Clock::at(0);
    let elsewhere = failing_elsewhere(fx.admin(), &[TWO, THREE], &transport, &clock).await;
    let id = stage_removal(&fx).await;
    let frozen = row(fx.admin(), &id).await;
    clock.set(SECOND_MS);
    assert_eq!(
        drive(fx.admin(), &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        row(fx.admin(), &id).await.statuses[1],
        FanoutTargetStatus::NotAttempted
    );
    transport.calls();

    // The commit loses: between two processes its stored row is given the
    // state branch selection gives a commit a rival displaced.
    let (admin, _others, group) = split(fx);
    let (db, key) = db_of(&admin);
    let CircleMember { circle, keys, dir } = admin;
    drop(circle);
    edit_closed_store_for_test(
        &db,
        &key,
        StoreEdit::MessageState {
            id: frozen.event_id.as_bytes(),
            state: MessageState::EpochInvalidated,
        },
    )
    .expect("the stored commit is marked as having lost");
    let admin = CircleMember {
        circle: std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ),
        keys,
        dir,
    };
    let epoch = admin.session().epoch(&group).await.expect("epoch");

    clock.set(10 * SECOND_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    let sent = transport.calls();
    assert_eq!(
        calls_to(&sent, TWO, frozen.event_id),
        1,
        "a frozen relay was not sent a commit because the commit had since lost",
    );
    assert!(sent.iter().all(|call| call.payload == frozen.payload));
    assert_eq!(
        commit_state(&admin, frozen.event_id).await,
        Some(MessageState::EpochInvalidated),
        "the driver changed the stored state of a commit it only had to send",
    );
    assert_eq!(admin.session().epoch(&group).await.expect("epoch"), epoch);
    // One relay holds it, one cannot be reached: retried, and ended a day
    // after its first acknowledgement like any other — after which it makes
    // no call.
    assert!(probe(&admin, &id).await.is_some());
    clock.set(DAY_MS + SECOND_MS);
    let _ = drive(&admin, &transport, &clock, &id).await;
    transport.calls();
    clock.set(DAY_MS + 2 * HOUR_MS);
    let _ = drive(&admin, &transport, &clock, &id).await;
    assert_eq!(
        transport.calls().len(),
        0,
        "a record past its bound was still calling a relay",
    );
    // Ended, and kept only while the other circle's commit still waits on
    // the relays it called: once they take that commit, the record goes.
    assert!(probe(&admin, &id).await.is_some());
    for relay in [TWO, THREE] {
        transport.answer(relay, [Answer::Accepted]);
    }
    clock.set(DAY_MS + 4 * HOUR_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &elsewhere).await.status,
        FanoutStatus::Confirmed
    );
    let _ = drive(&admin, &transport, &clock, &id).await;
    assert!(
        probe(&admin, &id).await.is_none(),
        "a record that had ended outlived every wait its going could change",
    );
}

// ── An eviction released inside a confirm's own fold ─────────────────────────

/// A commit whose acknowledgement was lost is on the relay and the other
/// members have applied it; one of them then leaves. The admin's device,
/// still awaiting its relay, holds that leave for the epoch it has not
/// reached. When the relay answers, the drive confirms the commit — and the
/// engine, inside that confirm's own fold, takes up the leave and stages the
/// eviction. The eviction is recorded in the hold that staged it, handed
/// back by the same drive, and sent in the same pass: nothing waits for
/// another wake, and nothing leaves the device without a record.
#[tokio::test]
async fn an_eviction_a_confirms_own_fold_releases_is_recorded_and_driven_in_the_same_pass() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let leaver = &others[1];
    let first = stage_relay_change(&admin, &group, &[ONE]).await;
    let frozen = row(&admin, &first).await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(&admin, &transport, &clock, &first).await.status,
        FanoutStatus::Unresolved
    );
    transport.calls();

    // The relay took it: the member applies it and proposes to leave.
    let commit =
        <nostr::Event as nostr::JsonUtil>::from_json(&frozen.payload).expect("the frozen event");
    leaver
        .session()
        .process_event_settled_for_test(&commit)
        .await
        .expect("the member applies the commit");
    let leave = leaver
        .circle
        .propose_leave(&group)
        .await
        .expect("the member proposes to leave")
        .expect("a first leave in this epoch proposes");
    // The admin's device takes the leave while its own commit still waits.
    let (_, staged) = admin
        .session()
        .process_event_staging_for_test(&leave, clock.now_ms(), &DriveMode::Full)
        .await
        .expect("the leave is taken");
    assert!(
        staged.is_empty() && staged_ref(&admin, &group).await.is_some(),
        "premise: nothing is staged beside the commit that is still awaiting its relay",
    );
    assert!(members_of(&admin, &group)
        .await
        .contains(&leaver.pubkey_hex()));

    // The relay answers. One pass: the confirm, and the eviction its fold
    // released.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(31 * SECOND_MS);
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        Some(&group),
        None,
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none());
    let [(confirmed, outcome), (eviction, evicted)] = <[_; 2]>::try_from(due.driven)
        .unwrap_or_else(|_| panic!("the pass did not drive the commit and then the eviction"));
    assert_eq!(
        (&confirmed, outcome.status),
        (&first, FanoutStatus::Confirmed)
    );
    assert_eq!(
        outcome.staged,
        std::slice::from_ref(&eviction),
        "the eviction the confirm's fold staged was not handed back by that drive",
    );
    assert_eq!(evicted.status, FanoutStatus::Confirmed);
    let sent = transport.calls();
    assert_eq!(
        sent.iter()
            .map(|call| call.event_id == frozen.event_id)
            .collect::<Vec<_>>(),
        [true, false],
        "the commit, then the eviction, each sent once under its own record",
    );
    assert!(
        !members_of(&admin, &group)
            .await
            .contains(&leaver.pubkey_hex())
            && staged_ref(&admin, &group).await.is_none(),
        "the member who left is still in the circle after the pass",
    );
}

/// The pubkeys `member` holds on `group`'s roster.
async fn members_of(member: &CircleMember, group: &GroupId) -> Vec<String> {
    member
        .session()
        .member_pubkeys(group)
        .await
        .expect("the roster")
}

// ── Nothing brings an ended record back ──────────────────────────────────────

/// MDK's put is an upsert. An answer that arrives after its record has ended
/// is not stored: the driver's update refuses a row the store no longer
/// holds, and the record stays gone.
#[tokio::test]
async fn an_answer_that_outlives_its_record_never_brings_the_record_back() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );

    // The silent relay is called again; while the call is under way the
    // record ends; then the relay answers.
    transport.answer(TWO, [Answer::Accepted]);
    transport.park();
    clock.set(HOUR_MS);
    let driving = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full);
    tokio::pin!(driving);
    tokio::select! {
        biased;
        _ = &mut driving => panic!("the drive finished while its call was parked"),
        () = transport.parked() => {}
    }
    admin
        .session()
        .end_fanout_for_test(&id)
        .await
        .expect("the record ends under the drive");
    transport.unpark();
    assert!(
        driving.await.expect("the drive runs").error.is_some(),
        "a drive stored an answer for a record that had ended",
    );
    assert!(
        probe(admin, &id).await.is_none() && !is_owned(&event),
        "an answer that arrived after its record ended wrote the record back",
    );
    assert!(rows_of(admin, &fx.group).await.is_empty());
}

// ── The wake's budget ────────────────────────────────────────────────────────

/// A transport whose every call takes time on the test's clock.
struct Slow<'a> {
    inner: &'a ScriptedFanout,
    clock: &'a Clock,
    takes_ms: u64,
}

#[async_trait::async_trait]
impl FanoutSend for Slow<'_> {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        self.clock.0.fetch_add(self.takes_ms, Ordering::SeqCst);
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &nostr::Event,
        targets: &[String],
    ) -> haven_core::relay::RelayResult<haven_core::relay::PublishResult> {
        self.inner.publish_location(event, targets).await
    }
}

/// A drive takes a row up only while the wake has time left for a relay that
/// never answers, and stops BETWEEN rows: the rows it leaves are exactly as
/// they were, said to be due, and driven by the next wake.
#[tokio::test]
async fn a_drive_stops_at_its_wake_budget_and_loses_nothing() {
    let fx = setup_circle(2, &[ONE]).await;
    let admin = fx.admin();
    let first = stage_removal(&fx).await;
    let other = solo_circle(admin, &[TWO]).await;
    let second = stage_relay_change(admin, &other, &[TWO, THREE]).await;
    let untouched = row(admin, &second).await;
    let scripted = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    assert_eq!(
        ROW_BUDGET_MS,
        (GATE_WAIT_SECS + MDK_CALL_CEILING_SECS + 6) * SECOND_MS,
        "a row's budget is the wait for its relay, MDK's ceiling for the call, \
         and the six deadlines of a second each its resolution's fold may wait out",
    );
    let transport = Slow {
        inner: &scripted,
        clock: &clock,
        takes_ms: 15 * SECOND_MS,
    };

    // Less than one row's budget left: nothing is begun.
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        None,
        Some(clock.now_ms() + ROW_BUDGET_MS - 1),
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none() && due.driven.is_empty());
    assert_eq!(due.retry_after_ms, Some(0));
    assert_eq!(scripted.call_count(), 0);

    // Room for one call and not, once it has taken fifteen seconds, for a
    // second.
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        None,
        Some(clock.now_ms() + ROW_BUDGET_MS + 10 * SECOND_MS),
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none());
    assert_eq!(
        due.driven
            .iter()
            .map(|(id, outcome)| (id.clone(), outcome.status))
            .collect::<Vec<_>>(),
        [(first, FanoutStatus::Confirmed)],
        "a row was begun with less of the wake left than one row can take",
    );
    assert_eq!(
        due.retry_after_ms,
        Some(0),
        "the rows left were not said to be due"
    );
    let left = row(admin, &second).await;
    assert!(
        left.statuses == untouched.statuses
            && left.attempts == untouched.attempts
            && left.mls == FanoutMls::Pending
            && staged_ref(admin, &other).await.is_some(),
        "a row the wake had no time for was touched",
    );
    assert_eq!(scripted.calls().len(), 1);

    // The next wake, with time, takes it up.
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
    assert_eq!(due.driven.len(), 1);
    assert_eq!(due.driven[0].1.status, FanoutStatus::Confirmed);
    assert!(staged_ref(admin, &other).await.is_none());
}

// ── A relay's schedule, with applied commits' records on it ──────────────────

/// The whole of what an applied commit asks of a relay that keeps failing it:
/// the schedule every row shares — ten calls in the hour after the first when
/// the relay cannot be reached, seven when it is silent, six when it says
/// "not now", and one an hour after that — and nothing at all once the record
/// has ended at its bound.
#[tokio::test]
async fn an_applied_commits_failing_relay_is_called_on_the_schedule_and_never_after_its_bound() {
    for (answer, first_hour) in [
        (Answer::Unreachable, 10),
        (Answer::Silent, 7),
        (Answer::RateLimited, 6),
    ] {
        let fx = setup_circle(2, &[ONE, TWO]).await;
        let admin = fx.admin();
        let id = stage_removal(&fx).await;
        let event = row(admin, &id).await.event_id;
        let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[answer])]);
        let clock = Clock::at(0);
        // Every second for the first minute, where the waits are shortest;
        // every five until the last wait under an hour has passed; then every
        // minute, through the bound and four hours past it.
        let mut call_times: Vec<u64> = Vec::new();
        let mut at = 0;
        while at < DAY_MS + 4 * HOUR_MS {
            clock.set(at);
            let status = drive(admin, &transport, &clock, &id).await.status;
            assert_eq!(
                status,
                if at < DAY_MS || (at == DAY_MS && status == FanoutStatus::Confirmed) {
                    FanoutStatus::Confirmed
                } else {
                    FanoutStatus::Gone
                },
                "at {at} ms ({answer:?})",
            );
            call_times.extend(
                transport
                    .calls()
                    .iter()
                    .filter(|call| call.target == TWO && call.event_id == event)
                    .map(|_| at),
            );
            at += match at {
                at if at < 60 * SECOND_MS => SECOND_MS,
                at if at < 40 * 60 * SECOND_MS => 5 * SECOND_MS,
                _ => 60 * SECOND_MS,
            };
        }
        assert_eq!(
            call_times.iter().filter(|at| **at < HOUR_MS).count(),
            first_hour,
            "calls to a failing relay in the first hour ({answer:?})",
        );
        for hour in 1..24 {
            let calls = call_times
                .iter()
                .filter(|at| **at >= hour * HOUR_MS && **at < (hour + 1) * HOUR_MS)
                .count();
            assert!(
                calls <= 1,
                "{calls} calls in hour {} ({answer:?})",
                hour + 1
            );
        }
        assert!(
            call_times.len() <= first_hour + 23,
            "more calls in a commit's day than the schedule has ({answer:?})",
        );
        assert!(
            call_times.len() > first_hour,
            "premise: the relay was still being retried after its first hour",
        );
        assert!(
            call_times.iter().all(|at| *at < DAY_MS),
            "a relay was called for a commit past its bound ({answer:?})",
        );
        assert!(probe(admin, &id).await.is_none());
    }
}

// ── The device's clock ───────────────────────────────────────────────────────

/// A clock that is stepped never leaves a relay unasked for the size of the
/// step, never keeps an applied commit's record alive for it, and never, on
/// its own, undoes a pending commit.
#[tokio::test]
async fn a_stepped_clock_never_starves_a_retry_and_never_undoes_a_commit_on_its_own() {
    // BACK, pending: the relay's last attempt now lies ten hours ahead of
    // the clock. It is asked at once, not in ten hours.
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let clock = Clock::at(10 * HOUR_MS);
    let _ = drive(fx.admin(), &transport, &clock, &id).await;
    clock.set(0);
    let _ = drive(fx.admin(), &transport, &clock, &id).await;
    assert_eq!(
        transport.calls().len(),
        2,
        "a clock stepped back left a pending commit's relay unasked",
    );

    // BACK, applied: a stored instant ahead of the clock means the record's
    // age cannot be known. It ends rather than live on for the step.
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Unreachable])]);
    let clock = Clock::at(10 * HOUR_MS);
    assert_eq!(
        drive(fx.admin(), &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert!(probe(fx.admin(), &id).await.is_some());
    clock.set(2 * HOUR_MS);
    let _ = drive(fx.admin(), &transport, &clock, &id).await;
    assert!(
        probe(fx.admin(), &id).await.is_none(),
        "an applied commit's record was kept alive by a clock stepped back",
    );
    assert_eq!(settled_members(fx.admin(), &fx.group).await, Some(1));

    // FORWARD, applied: it ends early. That costs retries, never the commit.
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let clock = Clock::at(0);
    let _ = drive(fx.admin(), &transport, &clock, &id).await;
    clock.set(30 * HOUR_MS);
    let _ = drive(fx.admin(), &transport, &clock, &id).await;
    assert!(probe(fx.admin(), &id).await.is_none());
    assert_eq!(settled_members(fx.admin(), &fx.group).await, Some(1));

    // BACK, pending and never exposed: ending it is a rollback, so a clock
    // that reads before the bound undoes nothing — here for a commit really
    // staged twenty-three hours before the step.
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_relay_change(fx.admin(), &fx.group, &[ONE, TWO]).await;
    let transport = answering(&[(ONE, &[Answer::Unreachable])]);
    let clock = Clock::at(23 * HOUR_MS);
    let _ = drive(fx.admin(), &transport, &clock, &id).await;
    for hours in [1, 5, 23] {
        clock.set(hours * HOUR_MS);
        assert_eq!(
            drive(fx.admin(), &transport, &clock, &id).await.status,
            FanoutStatus::Unresolved,
            "a pending commit was undone on a clock that reads before its bound",
        );
    }
    assert!(staged_ref(fx.admin(), &fx.group).await.is_some());

    // FORWARD, pending and never exposed: a clock thrown a day ahead finds
    // every relay due, so each is asked once more before anything is undone —
    // and a relay that answers applies the commit instead.
    for (answer, expected) in [
        (Answer::Accepted, FanoutStatus::Confirmed),
        (Answer::Unreachable, FanoutStatus::RolledBack),
    ] {
        let fx = setup_circle(3, &[ONE]).await;
        let id = stage_relay_change(fx.admin(), &fx.group, &[ONE, TWO]).await;
        let transport = answering(&[(ONE, &[Answer::Unreachable, answer])]);
        let clock = Clock::at(0);
        let _ = drive(fx.admin(), &transport, &clock, &id).await;
        transport.calls();
        clock.set(30 * HOUR_MS);
        assert_eq!(
            drive(fx.admin(), &transport, &clock, &id).await.status,
            expected
        );
        assert_eq!(
            transport.calls().len(),
            1,
            "a commit was undone on the clock's word, with no relay asked again",
        );
    }
}

// ── Back on a network ────────────────────────────────────────────────────────

/// MDK's own wake: when the device is back on a network, a relay that could
/// not be reached is due again at once. A relay that answered "not now" was
/// reached, and keeps its wait.
#[tokio::test]
async fn a_relay_that_could_not_be_reached_is_due_again_once_the_device_is_back_online() {
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let unreachable = stage_removal(&fx).await;
    let other = solo_circle(admin, &[TWO]).await;
    let limited = stage_relay_change(admin, &other, &[TWO, THREE]).await;
    let transport = answering(&[(ONE, &[Answer::Unreachable]), (TWO, &[Answer::RateLimited])]);
    let clock = Clock::at(0);
    for id in [&unreachable, &limited] {
        let _ = drive(admin, &transport, &clock, id).await;
    }
    transport.calls();

    // A second later neither is due.
    clock.set(SECOND_MS);
    for id in [&unreachable, &limited] {
        let _ = drive(admin, &transport, &clock, id).await;
    }
    assert_eq!(
        transport.calls().len(),
        0,
        "premise: both relays are waiting"
    );

    wake_unreachable(&admin.circle)
        .await
        .expect("the wake runs");
    for id in [&unreachable, &limited] {
        let _ = drive(admin, &transport, &clock, id).await;
    }
    let sent = transport.calls();
    assert_eq!(
        sent.iter().filter(|call| call.target == ONE).count(),
        1,
        "a relay that could not be reached was not asked again once the device was back online",
    );
    assert_eq!(
        sent.iter().filter(|call| call.target == TWO).count(),
        0,
        "a relay that said \"not now\" was asked again because a network came back",
    );
}

// ── An `Err` from the confirm: the stored row decides ────────────────────────

/// A peer location `admin` holds unread behind its pending commit.
async fn buffer_a_location(fx: &CircleFixture) {
    let from_peer = location_from(&fx.members[1], &fx.group)
        .await
        .expect("the peer seals a location");
    assert!(
        fx.admin()
            .circle
            .ingest_for_test(&from_peer)
            .await
            .expect("the ingest runs")
            .is_empty(),
        "premise: a location that arrives behind a pending commit is held",
    );
}

/// Whatever point the engine's confirm fails at, the error is never a failed
/// publish. Three points, three stored rows: before the merge (the row is
/// still pending), after the merge and before the engine left
/// `PendingPublish` (confirmed, and the engine still holds the commit), and
/// in the replay after it did (confirmed, nothing held). In each the commit
/// is never rolled back or retired, and the next drive — reading the stored
/// row, and writing to no relay — leaves it applied.
#[tokio::test]
async fn a_confirm_error_is_decided_by_the_stored_fanout_row() {
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum FailsAt {
        BeforeTheMerge,
        AfterTheMerge,
        InTheReplay,
    }
    for fails_at in [
        FailsAt::BeforeTheMerge,
        FailsAt::AfterTheMerge,
        FailsAt::InTheReplay,
    ] {
        let fx = setup_circle(3, &[ONE]).await;
        let admin = fx.admin();
        let (db, key) = db_of(admin);
        let source = admin.session().epoch(&fx.group).await.expect("epoch");
        let id = stage_removal(&fx).await;
        let event = row(admin, &id).await.event_id;
        buffer_a_location(&fx).await;
        let transport = answering(&[(ONE, &[Answer::Accepted])]);
        let clock = Clock::at(0);

        let arm = |armed: bool| match fails_at {
            FailsAt::BeforeTheMerge => {
                if armed {
                    admin.session().fail_next_confirms_for_test(&[false]);
                }
            }
            FailsAt::AfterTheMerge => {
                set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, armed)
                    .expect("the fault is set");
            }
            FailsAt::InTheReplay => {
                set_stored_message_write_fault_sparing_for_test(&db, &key, event.as_bytes(), armed)
                    .expect("the fault is set");
            }
        };
        arm(true);
        let failed = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full).await;
        arm(false);
        let delivered = match failed {
            Err(_) => 0,
            Ok(outcome) => {
                assert!(
                    outcome.error.is_some(),
                    "premise: the confirm failed ({fails_at:?})",
                );
                assert_ne!(outcome.status, FanoutStatus::RolledBack);
                locations(&outcome)
            }
        };
        assert_eq!(transport.calls().len(), 1);

        // What the store says, which is all that says where the commit is.
        let stored = row(admin, &id).await;
        let held = staged_ref(admin, &fx.group).await.is_some();
        assert_eq!(
            (stored.mls, held),
            match fails_at {
                FailsAt::BeforeTheMerge => (FanoutMls::Pending, true),
                FailsAt::AfterTheMerge => (FanoutMls::Confirmed, true),
                FailsAt::InTheReplay => (FanoutMls::Confirmed, false),
            },
            "{fails_at:?}",
        );
        assert_eq!(stored.statuses, [FanoutTargetStatus::Accepted]);
        assert_ne!(
            commit_state(admin, event).await,
            Some(MessageState::Failed),
            "a failed confirm retired an acknowledged commit ({fails_at:?})",
        );

        // The next drive finishes it from the stored row alone.
        clock.set(SECOND_MS);
        let outcome = drive(admin, &transport, &clock, &id).await;
        assert_eq!(outcome.status, FanoutStatus::Confirmed, "{fails_at:?}");
        assert!(outcome.error.is_none());
        assert_eq!(
            transport.calls().len(),
            0,
            "a relay was written to again to finish a confirm ({fails_at:?})",
        );
        assert!(staged_ref(admin, &fx.group).await.is_none());
        assert_eq!(settled_members(admin, &fx.group).await, Some(2));
        assert!(can_send(admin, &fx.group).await);
        // A replay that failed delivered nothing and keeps what it could not
        // replay for the engine's next pass; either other failure leaves the
        // held location to the confirm that finishes.
        if fails_at != FailsAt::InTheReplay {
            assert_eq!(
                delivered + locations(&outcome),
                1,
                "the location held behind the commit was not handed back ({fails_at:?})",
            );
        }
        assert!(probe(admin, &id).await.is_none());
    }
}

/// The engine merged the commit and stored its row as confirmed, and failed
/// before it left `PendingPublish`. Until the next drive the commit is still
/// the driver's alone — every legacy resolver handed the engine's ref is
/// refused, so nothing can rewind the engine under a commit the store has
/// applied — and the record is not ended. The next drive finishes with the
/// plain confirm, in the same session: the circle sends again without a
/// reopen, and the invite's Welcome is released then.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_confirm_that_failed_after_the_durable_merge_is_finished_by_the_plain_confirm() {
    let fx = setup_circle(2, &[ONE]).await;
    let admin = fx.admin();
    let (db, key) = db_of(admin);
    let source = admin.session().epoch(&fx.group).await.expect("epoch");
    let joiner = CircleMember::new();
    let event =
        helpers::create_key_package_event(joiner.session(), &joiner.keys, &[ONE.to_string()]).await;
    let id = admin
        .circle
        .add_members_staging(
            &fx.group,
            &[haven_core::circle::MemberKeyPackage {
                key_package_event: event,
                inbox_relays: vec!["wss://joiner-inbox.example.com".to_string()],
                nip65_relays: Vec::new(),
            }],
            STAGED_AT,
        )
        .await
        .expect("the invite is staged")
        .commit
        .expect("the invite's one commit is recorded");
    let frozen = row(admin, &id).await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let clock = Clock::at(0);

    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    let failed = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("a commit applied beside an error was reported as the error"));
    assert!(
        failed.error.is_some()
            && admin
                .session()
                .welcome_record_for_test(&frozen.welcome_ids[0])
                .await
                .is_none(),
        "premise: the confirm failed, and released nothing",
    );
    assert_eq!(
        failed.status,
        FanoutStatus::Confirmed,
        "a commit the store had applied read as unresolved because its confirm returned an error",
    );
    let pending = staged_ref(admin, &fx.group)
        .await
        .expect("premise: the engine has not left PendingPublish");
    let stored = row(admin, &id).await;
    assert_eq!(
        stored.mls,
        FanoutMls::Confirmed,
        "premise: merged and stored"
    );
    assert_eq!(stored.held_welcomes, 1);
    assert!(!can_send(admin, &fx.group).await, "premise: sends are held");

    // No other path may be handed the ref.
    assert!(matches!(
        admin.session().publish_failed(pending).await,
        Err(NostrError::FanoutOwned)
    ));
    assert!(matches!(
        admin.session().confirm_published(pending).await,
        Err(NostrError::FanoutOwned)
    ));
    assert_eq!(staged_ref(admin, &fx.group).await, Some(pending));

    // While it cannot be finished the record stays, though one relay — all
    // it was frozen for — holds the commit.
    clock.set(SECOND_MS);
    let again = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("a commit applied beside an error was reported as the error"));
    assert!(again.error.is_some());
    assert_eq!(again.status, FanoutStatus::Confirmed);
    assert_eq!(
        row(admin, &id).await.mls,
        FanoutMls::Confirmed,
        "a record was ended while the engine still held its commit",
    );
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");

    clock.set(2 * SECOND_MS);
    let mut outcome = None;
    let lines = capture_haven_log(async {
        outcome = Some(drive(admin, &transport, &clock, &id).await);
    })
    .await;
    let outcome = outcome.expect("ran");
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert_eq!(transport.calls().len(), 1, "a relay was written to again");
    assert!(
        staged_ref(admin, &fx.group).await.is_none() && can_send(admin, &fx.group).await,
        "the circle still refuses sends after the confirm was finished",
    );
    assert_eq!(settled_members(admin, &fx.group).await, Some(3));
    assert!(
        admin
            .session()
            .welcome_record_for_test(&frozen.welcome_ids[0])
            .await
            .is_some_and(|(commit, _, _)| {
                commit.as_slice() == frozen.event_id.as_bytes().as_slice()
            }),
        "the invite's Welcome was not handed to its delivery record when the confirm was \
         finished",
    );
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "stored but did not finish")),
        &[
            &hex::encode(fx.group.as_slice()),
            &frozen.event_id.to_hex(),
            CANARY,
        ],
    );
}

/// A row that already holds an acknowledgement needs no relay to be confirmed:
/// after a confirm that failed, the next drive confirms it and sends nothing.
/// Here the failure is a store that stayed busy — asked again four times in
/// the one drive, and no more.
#[tokio::test]
async fn a_pending_row_with_an_accepted_target_is_reconfirmed_on_the_next_drive_without_a_relay_write(
) {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);

    admin
        .session()
        .fail_next_confirms_for_test(&[true, true, true, true, true]);
    assert!(
        drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .is_err(),
        "premise: the store stayed busy",
    );
    assert_eq!(
        admin.session().confirm_faults_left_for_test(),
        1,
        "a busy store was not asked to confirm exactly four times in one drive",
    );
    let stored = row(admin, &id).await;
    assert_eq!(stored.mls, FanoutMls::Pending);
    assert_eq!(
        stored.statuses,
        [
            FanoutTargetStatus::Accepted,
            FanoutTargetStatus::PossiblyExposed
        ],
        "the acknowledgement was not stored before the confirm was asked for",
    );
    assert!(
        staged_ref(admin, &fx.group).await.is_some()
            && commit_state(admin, event).await == Some(MessageState::Sent),
        "a confirm that failed rolled the commit back",
    );
    assert_eq!(transport.calls().len(), 2);

    // The store is busy once more, then answers: the same call asks again.
    let outcome = drive(admin, &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert_eq!(admin.session().confirm_faults_left_for_test(), 0);
    assert_eq!(
        transport.calls().len(),
        0,
        "a relay was written to in order to confirm a commit it had already acknowledged",
    );
    assert_eq!(settled_members(admin, &fx.group).await, Some(2));
}

/// Only an error the store calls transient is asked again, and the asking is
/// bounded: one that is not is returned at once, untouched.
#[tokio::test]
async fn only_a_busy_store_is_asked_to_confirm_again() {
    // Not transient: no second ask, although the next would have been.
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    admin.session().fail_next_confirms_for_test(&[false, true]);
    assert!(
        drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .is_err()
    );
    assert_eq!(
        admin.session().confirm_faults_left_for_test(),
        1,
        "an error that was not transient was retried in the call",
    );
    assert!(staged_ref(admin, &fx.group).await.is_some());

    // Busy once: confirmed by the second ask of the same drive.
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    admin.session().fail_next_confirms_for_test(&[true]);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed,
        "a store that was busy once stranded an acknowledged commit until another drive",
    );
    assert_eq!(admin.session().confirm_faults_left_for_test(), 0);
}

// ── What a drive collected is never dropped with an error ────────────────────

/// A resolution that fails hands back what the engine had already emitted —
/// folded, beside its error — instead of the error alone: here the
/// announcement of a commit an open cleared, which nothing else will ever
/// deliver. The commit it failed to confirm is not rolled back, and the next
/// drive confirms it.
#[tokio::test]
async fn a_failed_resolution_hands_back_what_it_left_beside_its_error() {
    use haven_core::nostr::mls::types::LocationMessageResult;

    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    // Another circle's change, staged with no record: the next open clears
    // it and leaves its announcement with the engine.
    let other = solo_circle(fx.admin(), &[TWO]).await;
    stage_a_commit_the_next_open_clears(fx.admin(), &other, THREE).await;
    let (admin, _others, group) = split(fx);
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "premise: restored"
    );

    admin.session().fail_next_confirms_for_test(&[false]);
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let outcome = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("what a failed confirm left was dropped for its error"));
    assert!(outcome.error.is_some(), "premise: the confirm failed");
    assert!(
        outcome
            .replayed
            .results
            .iter()
            .any(|result| matches!(result, LocationMessageResult::GroupUpdate { .. })),
        "what the engine had emitted was not folded into what the drive returned",
    );
    assert_eq!(outcome.status, FanoutStatus::Unresolved);
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && row(&admin, &id).await.statuses == [FanoutTargetStatus::Accepted],
        "a failed confirm undid the commit or its acknowledgement",
    );
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
}

/// A row whose resolution fails does not stop the pass for every circle: the
/// rest of ITS circle's rows wait behind it, the other circles' rows are
/// driven, and the first error comes back beside everything driven — the
/// failed row's own drive, with what it folded, included.
#[tokio::test]
async fn a_rows_error_stops_its_own_circle_and_no_other() {
    use haven_core::nostr::mls::types::LocationMessageResult;

    let fx = setup_circle(3, &[ONE, TWO]).await;
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Unreachable]),
        (THREE, &[Answer::Accepted]),
    ]);
    let clock = Clock::at(0);
    // The circle's first commit is applied and still owed to one relay; its
    // second is staged behind it.
    let older = stage_removal(&fx).await;
    assert_eq!(
        drive(fx.admin(), &transport, &clock, &older).await.status,
        FanoutStatus::Confirmed
    );
    let older_event = row(fx.admin(), &older).await.event_id;
    let newer = the_one(
        fx.admin()
            .session()
            .remove_members_staging(&fx.group, &[fx.members[1].pubkey_hex()], STAGED_AT)
            .await
            .expect("the circle's next change is staged")
            .fanouts,
    );
    // Another circle's commit, and a third circle whose cleared commit the
    // next open announces into the engine's buffer.
    let elsewhere = solo_circle(fx.admin(), &[THREE]).await;
    let other = stage_relay_change(fx.admin(), &elsewhere, &[THREE, TWO]).await;
    let cleared = solo_circle(fx.admin(), &[THREE]).await;
    stage_a_commit_the_next_open_clears(fx.admin(), &cleared, ONE).await;
    let (admin, _others, group) = split(fx);
    let admin = admin.reopen();
    transport.calls();

    // The first confirm asked — the circle's newer commit, which a relay
    // acknowledges — fails. Ten seconds on, the older record's relay is due.
    admin.session().fail_next_confirms_for_test(&[false]);
    clock.set(10 * SECOND_MS);
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        None,
        None,
        &DriveMode::Full,
    )
    .await;

    assert!(
        due.error.is_some(),
        "the failure was lost behind a later row"
    );
    assert_eq!(
        due.erred,
        Some(vec![group.clone()]),
        "the failure was not placed in its own circle alone: another circle's wait for the \
         foreground would be held by it, or this one's ended",
    );
    let [(failed_at, failed), (driven_after, after)] = <[_; 2]>::try_from(due.driven)
        .unwrap_or_else(|_| {
            panic!(
                "a failed row stopped the pass for another circle, or did not stop \
                 its own circle's older row"
            )
        });
    assert!(
        failed_at == newer && driven_after == other,
        "premise: the rows were taken in staging order, first attempts first",
    );
    assert!(
        failed
            .replayed
            .results
            .iter()
            .any(|result| matches!(result, LocationMessageResult::GroupUpdate { .. })),
        "what the failed row's drive had folded was dropped",
    );
    assert_eq!(failed.status, FanoutStatus::Unresolved);
    assert_eq!(
        after.status,
        FanoutStatus::Confirmed,
        "a circle's commit went undriven because another circle's row failed",
    );
    assert!(staged_ref(&admin, &group).await.is_some());
    assert!(staged_ref(&admin, &elsewhere).await.is_none());
    assert_eq!(
        calls_to(&transport.calls(), TWO, older_event),
        0,
        "a circle's older row was driven behind the row of its own that had just failed",
    );

    // The next pass, once that relay is due again, finishes both of the
    // circle's rows.
    clock.set(20 * SECOND_MS);
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
    assert!(staged_ref(&admin, &group).await.is_none());
    assert_eq!(calls_to(&transport.calls(), TWO, older_event), 1);
}

/// A transport that makes the next confirm fail once it has been asked for
/// `relay`.
struct FailingConfirmAfter<'a> {
    inner: &'a ScriptedFanout,
    session: &'a SessionManager,
    relay: &'a str,
}

#[async_trait::async_trait]
impl FanoutSend for FailingConfirmAfter<'_> {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        if target == self.relay {
            self.session.fail_next_confirms_for_test(&[false]);
        }
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &nostr::Event,
        targets: &[String],
    ) -> haven_core::relay::RelayResult<haven_core::relay::PublishResult> {
        self.inner.publish_location(event, targets).await
    }
}

/// When a later row's drive fails, what the earlier rows' drives released —
/// here a peer's location held behind the first circle's commit — comes back
/// beside the error, never instead of it.
#[tokio::test]
async fn what_earlier_rows_released_is_returned_beside_a_later_rows_error() {
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let first = stage_removal(&fx).await;
    buffer_a_location(&fx).await;
    let other = solo_circle(admin, &[TWO]).await;
    let second = stage_relay_change(admin, &other, &[TWO, THREE]).await;
    let scripted = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let transport = FailingConfirmAfter {
        inner: &scripted,
        session: admin.session(),
        relay: TWO,
    };

    let due = drive_due(
        &admin.circle,
        &transport,
        &Clock::at(0),
        None,
        None,
        &DriveMode::Full,
    )
    .await;
    assert!(
        due.error.is_some(),
        "premise: the second row's confirm failed"
    );
    let [(driven, outcome)] = <[_; 1]>::try_from(due.driven)
        .unwrap_or_else(|_| panic!("the first row's drive is returned, and only it"));
    assert_eq!(driven, first);
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert_eq!(
        locations(&outcome),
        1,
        "what the first drive released was dropped with the second's error",
    );
    assert!(
        staged_ref(admin, &other).await.is_some() && probe(admin, &second).await.is_some(),
        "the failed row was not left for the next drive",
    );
}

// ── A commit a relay may hold that the engine no longer stages ───────────────

/// The one state the driver can neither confirm nor discard: a relay may
/// hold the commit and the engine no longer stages it. It blocks the circle's
/// next change, and it has an exit — the engine's own convergence disposes of
/// the commit at the first deadline any plane serves. The record is then
/// settled by the next drive, and the circle takes changes again.
#[tokio::test]
async fn a_commit_a_relay_may_hold_that_is_no_longer_staged_stops_blocking_once_the_engine_disposes_of_it(
) {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);
    let _ = drive(admin, &transport, &clock, &id).await;
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    let (db, key) = db_of(admin);
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && commit_state(admin, event).await == Some(MessageState::Sent),
        "premise: not staged, and still stored as sent",
    );
    transport.calls();

    // Blocked, for as long as the commit is unresolved — a day changes
    // nothing, and nothing is sent under the record.
    let other = [fx.members[1].pubkey_hex()];
    for hours in [1, 30] {
        clock.set(hours * HOUR_MS);
        assert_eq!(
            drive(admin, &transport, &clock, &id).await.status,
            FanoutStatus::Unresolved
        );
        assert!(matches!(
            admin.session().remove_members(&fx.group, &other).await,
            Err(NostrError::EpochNotStable)
        ));
    }
    assert_eq!(transport.calls().len(), 0);
    assert_eq!(row(admin, &id).await.mls, FanoutMls::Pending);

    // Any plane serving the engine's deadline ends it.
    serve_deadlines(admin, &fx.group).await;
    assert_ne!(
        commit_state(admin, event).await,
        Some(MessageState::Sent),
        "the engine did not dispose of a commit it no longer stages",
    );
    clock.set(31 * HOUR_MS);
    let status = drive(admin, &transport, &clock, &id).await.status;
    assert!(
        matches!(status, FanoutStatus::Stale | FanoutStatus::Confirmed),
        "the record of a commit the engine disposed of was left as it was: {status:?}",
    );
    assert_ne!(
        probe(admin, &id).await.map(|row| row.mls),
        Some(FanoutMls::Pending)
    );
    admin
        .session()
        .remove_members(&fx.group, &other)
        .await
        .expect("the circle takes a change again");
}

// ── Welcomes ─────────────────────────────────────────────────────────────────

/// A Welcome is released only while its commit is still this device's
/// canonical one. An invite whose commit has since lost for good to a rival
/// branch would welcome its recipient into an epoch the circle never
/// reached: nothing is handed over, nothing waits, the Welcome ends as
/// failed — never as delivered — and the record ends.
#[tokio::test]
async fn a_welcome_is_withheld_once_its_commit_is_no_longer_this_devices() {
    let fx = setup_circle(2, &[ONE]).await;
    let (db, key) = db_of(fx.admin());
    let source = fx.admin().session().epoch(&fx.group).await.expect("epoch");
    let joiner = CircleMember::new();
    let package = SessionManager::key_package_from_event(
        &helpers::create_key_package_event(joiner.session(), &joiner.keys, &[ONE.to_string()])
            .await,
    )
    .expect("a key package");
    let id = the_one(
        fx.admin()
            .session()
            .add_members_staging(&fx.group, vec![package], STAGED_AT)
            .await
            .expect("the invite is staged")
            .fanouts,
    );
    let frozen = row(fx.admin(), &id).await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    // Applied and stored, with the Welcome not yet released: the confirm
    // failed after its merge, and the process dies.
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    let _ = drive_one(
        &fx.admin().circle,
        &transport,
        &clock,
        &id,
        &DriveMode::Full,
    )
    .await;
    assert_eq!(row(fx.admin(), &id).await.held_welcomes, 1, "premise");
    assert!(
        fx.admin()
            .session()
            .outstanding_welcome_ids_for_test()
            .await
            .expect("welcomes")
            .contains(&frozen.welcome_ids[0]),
        "premise: the confirm that failed after its merge had promoted the Welcome",
    );
    let (admin, _others, _group) = split(fx);
    let CircleMember { circle, keys, dir } = admin;
    drop(circle);
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
    // The commit loses: its stored row is given the state branch selection
    // gives a commit a rival displaced.
    edit_closed_store_for_test(
        &db,
        &key,
        StoreEdit::MessageState {
            id: frozen.event_id.as_bytes(),
            state: MessageState::EpochInvalidated,
        },
    )
    .expect("the stored commit is marked as having lost");
    let admin = CircleMember {
        circle: std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ),
        keys,
        dir,
    };
    assert_eq!(row(&admin, &id).await.held_welcomes, 1);

    clock.set(SECOND_MS);
    let outcome = drive(&admin, &transport, &clock, &id).await;
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert!(
        admin
            .session()
            .welcome_record_for_test(&frozen.welcome_ids[0])
            .await
            .is_none(),
        "a Welcome was released for a commit that is no longer the circle's",
    );
    assert_eq!(
        admin
            .session()
            .stored_message_record_for_test(&frozen.welcome_ids[0])
            .await
            .expect("the store is read")
            .map(|record| record.state),
        Some(MessageState::Failed),
        "the Welcome of a commit that lost for good was ended as delivered, not failed",
    );
    assert!(
        !outcome.welcomes_withheld && outcome.notes.is_empty(),
        "a Welcome that will never be sent was said to be waiting, or its invitee \
         to be owed another invite to a circle they were never added to",
    );
    assert!(
        admin
            .session()
            .outstanding_welcome_ids_for_test()
            .await
            .expect("welcomes")
            .iter()
            .all(|id| *id != frozen.welcome_ids[0]),
        "the engine still holds for delivery the Welcome of a commit that lost for good",
    );
    assert!(probe(&admin, &id).await.is_none());
}

// ── The open, and what it cannot repair ──────────────────────────────────────

/// Ends `member`'s process, applies `edit` to its closed MLS store, and
/// starts another over it, returning what the open logged.
async fn reopen_after(member: CircleMember, edit: StoreEdit<'_>) -> (CircleMember, Vec<LogLine>) {
    let (db, key) = db_of(&member);
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    edit_closed_store_for_test(&db, &key, edit).expect("the closed store is edited");
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ));
    })
    .await;
    (
        CircleMember {
            circle: reopened.expect("reopened"),
            keys,
            dir,
        },
        lines,
    )
}

/// The engine stages a removal in several writes, and a process can die
/// between them. Where the store then shows a sent commit with neither mark
/// of a removal — an admin's Remove whose intent was not yet written, an
/// eviction whose record was not yet moved forward — the open cannot tell it
/// from a commit that removes nobody, and gives it no record: a record for
/// one that removes nobody would hold its circle behind a commit nothing the
/// app calls can resolve. The engine keeps such a removal attached, so this
/// circle is left as MDK leaves it, with nothing to send the commit — the
/// price of repairing removals only, paid until a product path drives
/// stored records and the repair covers every commit again
/// (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW).
#[tokio::test]
async fn a_removal_killed_inside_its_own_staging_shows_no_mark_and_is_given_no_record() {
    for own_remove in [true, false] {
        let fx = setup_circle(3, &[ONE, TWO]).await;
        let (admin, others, group) = split(fx);
        let commit = if own_remove {
            commit_event_id(
                &admin
                    .session()
                    .remove_members(&group, &[others[1].pubkey_hex()])
                    .await
                    .expect("a removal is staged"),
            )
        } else {
            stage_eviction(&admin, &others[1], &group).await
        };
        let edit = if own_remove {
            StoreEdit::ForgetOwnCommitIntent {
                commit: commit.as_bytes(),
            }
        } else {
            StoreEdit::RewindRecordEpoch { group: &group }
        };
        let (admin, lines) = reopen_after(admin, edit).await;
        assert!(
            rows_of(&admin, &group).await.is_empty() && !is_owned(&commit),
            "a commit the store cannot show to be a removal was given a record \
             (own remove: {own_remove})",
        );
        assert!(
            !lines
                .iter()
                .any(|line| line.message.contains("was given one")),
            "the open said it recorded a commit it left alone",
        );
        assert_eq!(
            commit_state(&admin, commit).await,
            Some(MessageState::Sent),
            "the open settled a commit it gave no record",
        );
    }
}

/// The eviction of a member who left, staged on `admin` by the engine's own
/// deadline with no fanout row.
async fn stage_eviction(
    admin: &CircleMember,
    leaver: &CircleMember,
    group: &GroupId,
) -> nostr::EventId {
    let leave = leaver
        .session()
        .leave_group(group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let proposal = SessionManager::proposal_events(&leave.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    let mut effects = match admin
        .session()
        .process_event(&proposal)
        .await
        .expect("ingest")
    {
        ScreenedIngest::Ingested(ingest) => ingest.effects,
        ScreenedIngest::RejectedBeforeAuth(_) => panic!("rejected"),
    };
    for _ in 0..8 {
        if effects
            .publish
            .iter()
            .any(|work| matches!(work, PublishWork::AutoPublish { .. }))
        {
            return commit_event_id(&effects);
        }
        let wait = admin
            .session()
            .receive_retick_after(group)
            .await
            .expect("the engine owes the eviction a deadline");
        tokio::time::sleep(wait).await;
        effects = admin
            .session()
            .stage_unrecorded_for_test(group)
            .await
            .expect("advance");
    }
    panic!("the eviction was never staged");
}

/// Two unresolved commits of one circle's own and no record: nothing says
/// which of them is attached, so neither is given one, and the open says so.
#[tokio::test]
async fn a_circle_with_two_unresolved_commits_and_no_record_is_given_none() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let first = commit_event_id(
        &admin
            .session()
            .remove_members(&group, &[others[1].pubkey_hex()])
            .await
            .expect("a removal is staged"),
    );
    // Rewound with its row left as sent, and another staged after it.
    let pending = staged_ref(&admin, &group).await.expect("staged");
    let (db, key) = db_of(&admin);
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin.session().publish_failed(pending).await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert_eq!(commit_state(&admin, first).await, Some(MessageState::Sent));
    let at = admin.session().epoch(&group).await.expect("the epoch");
    let left = admin
        .session()
        .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, at)
        .await
        .expect("the rewound commit's row");
    let admin = admin.reopen();
    let second = commit_event_id(
        &admin
            .session()
            .remove_members(&group, &[others[0].pubkey_hex()])
            .await
            .expect("another removal is staged"),
    );
    // As an earlier build left the store: it retired such a row only in the
    // session that rewound it, so a process that died first kept it beside
    // the next commit staged. This one retires it before its open's first
    // engine call; the row is put back as that build left it.
    admin
        .session()
        .stage_convergence_input_for_test(&left, MessageState::Sent, 0)
        .await
        .expect("the row stands again");
    assert_eq!(commit_state(&admin, first).await, Some(MessageState::Sent));

    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "more than one unresolved commit")),
        &[
            &hex::encode(group.as_slice()),
            &first.to_hex(),
            &second.to_hex(),
            CANARY,
        ],
    );
    assert!(rows_of(&admin, &group).await.is_empty());
}

/// Giving a repaired removal its relays is a delete and then a put. When the
/// put fails the engine holds a commit with no record again — said so, and
/// put right by the next open, which finds the removal as the first did.
#[tokio::test]
async fn a_repaired_removals_record_lost_while_it_was_given_its_relays_is_given_one_again() {
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
    // The trial names no relay and is written; the record that does is not.
    set_fanout_write_fault_naming_for_test(&db, &key, CANARY, true).expect("arm");
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    set_fanout_write_fault_naming_for_test(&db, &key, CANARY, false).expect("disarm");
    let admin = reopened.expect("reopened");
    assert!(
        rows_of(&admin, &group).await.is_empty() && staged_ref(&admin, &group).await.is_some(),
        "premise: the engine holds the removal and its record is gone",
    );
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "was lost while it was being given")),
        &[&hex::encode(group.as_slice()), &commit.to_hex(), CANARY],
    );

    let admin = admin.reopen();
    let id = the_one(rows_of(&admin, &group).await);
    let given = row(&admin, &id).await;
    assert_eq!(given.event_id, commit);
    assert_eq!(given.statuses, [FanoutTargetStatus::PossiblyExposed; 2]);
    assert!(staged_ref(&admin, &group).await.is_some());
}

/// A stale record the engine holds a second commit under, in a circle of
/// three: the record, and that commit.
struct StaleBound {
    admin: CircleMember,
    group: GroupId,
    stale: FanoutId,
    second: nostr::EventId,
}

async fn a_second_commit_bound_to_a_stale_record() -> StaleBound {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let stale = stage_removal(&fx).await;
    let (admin, others, group) = split(fx);
    // The first commit is discarded past its record, which stays pending.
    let pending = staged_ref(&admin, &group).await.expect("staged");
    admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await
        .expect("the bypass discards the first commit");
    let stale_event = row(&admin, &stale).await.event_id;
    assert_eq!(
        commit_state(&admin, stale_event).await,
        Some(MessageState::Failed)
    );
    // A second commit is staged with no record of its own, and the process
    // dies. The open cannot delete the stale record, so the engine binds it
    // to the second commit.
    let second = commit_event_id(
        &admin
            .session()
            .remove_members(&group, &[others[0].pubkey_hex()])
            .await
            .expect("a second removal is staged the legacy way"),
    );
    let (db, key) = db_of(&admin);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, true).expect("arm");
    let admin = admin.reopen();
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, false).expect("disarm");
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && row(&admin, &stale).await.mls == FanoutMls::Pending,
        "premise: the stale record survived the open and the engine holds a commit under it",
    );
    StaleBound {
        admin,
        group,
        stale,
        second,
    }
}

/// A commit the engine holds under ANOTHER commit's record is one nothing
/// here knows the history of: whoever staged it without a record may have
/// published it before the process died. So the driver neither rolls it back
/// nor retires it, sends nothing under the stale record, and says so; and no
/// deadline served afterwards merges or discards it. The next open settles
/// the stale record before the engine can bind it again and gives the commit
/// a record of its own, stored as possibly exposed — which a relay that
/// holds the commit then confirms.
#[tokio::test]
async fn a_commit_found_under_a_stale_record_is_never_rolled_back_and_gets_its_own_at_the_next_open(
) {
    let StaleBound {
        admin,
        group,
        stale,
        second,
    } = a_second_commit_bound_to_a_stale_record().await;
    let stale_event = row(&admin, &stale).await.event_id;
    let held = staged_ref(&admin, &group).await;

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let mut outcome = None;
    let lines = capture_haven_log(async {
        outcome = Some(drive(&admin, &transport, &Clock::at(HOUR_MS), &stale).await);
    })
    .await;
    let outcome = outcome.expect("ran");
    assert_eq!(outcome.status, FanoutStatus::Unresolved);
    assert!(outcome.error.is_none());
    assert_eq!(
        transport.calls().len(),
        0,
        "a stale record's event was sent"
    );
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "is left staged")),
        &[
            &hex::encode(group.as_slice()),
            &second.to_hex(),
            &stale_event.to_hex(),
            CANARY,
        ],
    );
    assert_eq!(
        staged_ref(&admin, &group).await,
        held,
        "a commit of unknown history was rolled back from under another commit's record",
    );
    assert_eq!(
        commit_state(&admin, second).await,
        Some(MessageState::Sent),
        "a commit a relay may hold was retired",
    );
    assert_eq!(row(&admin, &stale).await.mls, FanoutMls::Pending);
    // No pass a plane serves afterwards disposes of it either.
    serve_deadlines(&admin, &group).await;
    assert_eq!(staged_ref(&admin, &group).await, held);
    assert_eq!(commit_state(&admin, second).await, Some(MessageState::Sent));
    // Nor can the session's resolver, handed the ref, apply it without an
    // ack.
    assert!(matches!(
        admin
            .session()
            .confirm_published(held.expect("staged"))
            .await,
        Err(NostrError::FanoutOwned)
    ));

    // The next open, with a store that can be written.
    let admin = admin.reopen();
    assert!(
        probe(&admin, &stale).await.is_none(),
        "the stale record survived an open that could delete it",
    );
    let own = the_one(rows_of(&admin, &group).await);
    let given = row(&admin, &own).await;
    assert_eq!(given.event_id, second);
    assert_eq!(
        given.statuses,
        [FanoutTargetStatus::PossiblyExposed; 2],
        "the commit's own record was not stored as one a relay may hold",
    );
    assert_eq!(
        drive(&admin, &transport, &Clock::at(2 * HOUR_MS), &own)
            .await
            .status,
        FanoutStatus::Confirmed
    );
    assert_eq!(settled_members(&admin, &group).await, Some(2));
}

// ── What the repair rests on in the engine ───────────────────────────────────

/// Two things the open's repair takes from MDK without being promised them:
/// every stored circle is hydrated before the open returns — a record the
/// engine adopted is read back in the same open — and Haven never has the
/// engine write a durable group evolution, whose restore would mint a
/// pending ref of its own beside a trial's.
#[tokio::test]
async fn the_open_hydrates_every_circle_and_haven_writes_no_durable_evolution() {
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let (admin, others, group) = split(fx);
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some() && probe(&admin, &id).await.is_some(),
        "a stored circle was not hydrated by the time the open returned",
    );
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let _ = drive(&admin, &transport, &Clock::at(0), &id).await;
    // Every kind of change Haven stages has now been made by this session or
    // the fixture: a create, an invite, a removal, a relay change.
    let change = stage_relay_change(&admin, &group, &[ONE, TWO]).await;
    let _ = drive(&admin, &transport, &Clock::at(0), &change).await;
    drop(others);
    assert_eq!(
        admin
            .session()
            .group_evolution_count_for_test()
            .await
            .expect("the store is read"),
        0,
        "the engine holds a durable group evolution, which its hydrate restores \
         under a pending ref of its own",
    );
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
    )
    .expect("the session manager's source");
    assert!(
        !source.contains("defer_group_hydration") && source.contains("AccountDeviceSession::open("),
        "the session is opened with hydration deferred: a record the engine has \
         not yet adopted would be read back as one it does not hold",
    );
}

/// A circle quarantined at the open keeps its pending fanout row out of the
/// engine's sight, and with it the pending ref the row carries. Hydrating it
/// later in the same session would restore that ref beside whatever the
/// engine has handed out since — so the retry answers "still quarantined"
/// without asking the engine, and the next open takes the circle up.
#[tokio::test]
async fn a_quarantined_circle_with_a_pending_record_is_not_hydrated_inside_a_live_session() {
    use haven_core::nostr::mls::storage::{
        delete_openmls_group_state_for_test, openmls_group_keys_for_test,
    };

    let admin = CircleMember::new();
    let (db, key) = db_of(&admin);
    let healthy = solo_circle(&admin, &[ONE]).await;
    let CircleMember { circle, keys, dir } = admin;
    drop(circle);
    let before = openmls_group_keys_for_test(&db, &key).expect("the group keys are read");
    let admin = CircleMember {
        circle: std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ),
        keys,
        dir,
    };
    let victim = solo_circle(&admin, &[TWO]).await;
    let id = stage_relay_change(&admin, &victim, &[TWO, THREE]).await;
    let CircleMember { circle, keys, dir } = admin;
    drop(circle);
    let added: Vec<_> = openmls_group_keys_for_test(&db, &key)
        .expect("the group keys are read")
        .into_iter()
        .filter(|group| !before.contains(group))
        .collect();
    assert_eq!(added.len(), 1, "premise: one circle, one group key");
    assert!(
        delete_openmls_group_state_for_test(&db, &key, &added[0]).expect("deleted") > 0,
        "premise: the circle's group state is gone",
    );

    let admin = CircleMember {
        circle: std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ),
        keys,
        dir,
    };
    assert!(
        admin
            .session()
            .quarantined_group_ids()
            .await
            .contains(&victim),
        "premise: the circle is quarantined",
    );
    assert!(
        probe(&admin, &id).await.is_none(),
        "premise: the engine does not show a quarantined circle's row",
    );
    assert!(
        !admin
            .session()
            .retry_quarantined_group(&victim)
            .await
            .expect("the retry answers"),
        "a circle with a pending record was hydrated inside a live session",
    );
    assert!(can_send(&admin, &healthy).await);
}

// ── A commit that removes a member is never undone for want of a relay ───────

/// The eviction of `leaver`, staged on `admin` in staging mode — under its
/// durable fanout — by the engine's own deadline.
async fn stage_eviction_recorded(
    admin: &CircleMember,
    leaver: &CircleMember,
    group: &GroupId,
    now_ms: u64,
) -> FanoutId {
    let leave = leaver
        .session()
        .leave_group(group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let proposal = SessionManager::proposal_events(&leave.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    let _ = admin
        .session()
        .process_event(&proposal)
        .await
        .expect("ingest");
    restage_eviction(admin, group, now_ms)
        .await
        .expect("the eviction was never staged")
}

/// Serves the engine's deadlines for `group` in staging mode until an
/// advance stages a commit, and returns its record; `None` when eight
/// deadlines pass with none recorded.
async fn restage_eviction(admin: &CircleMember, group: &GroupId, now_ms: u64) -> Option<FanoutId> {
    for _ in 0..8 {
        let staged = admin
            .session()
            .advance_for_drive(group, now_ms)
            .await
            .expect("advance");
        if let Some(id) = staged.fanouts.into_iter().next() {
            return Some(id);
        }
        let wait = match admin.session().eviction_due_after_for_test(group).await {
            Some(wait) => wait,
            None => admin.session().receive_retick_after(group).await?,
        };
        tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
    }
    None
}

/// A day without a reachable relay undoes a change that removes nobody. It
/// never undoes one that removes a member — the user's own removal, or the
/// eviction of a member who left: undone, the circle's waiting locations
/// would go out to the very member it was meant to cut off. Such a commit
/// stays staged, shares nothing while it waits, keeps that standing across a
/// restart, and is applied by the first relay that answers.
#[tokio::test]
async fn a_removal_no_relay_can_be_reached_for_is_never_undone_at_the_bound() {
    for own_remove in [true, false] {
        let fx = setup_circle(3, &[ONE, TWO]).await;
        let (admin, others, group) = split(fx);
        let id = if own_remove {
            the_one(
                admin
                    .session()
                    .remove_members_staging(&group, &[others[1].pubkey_hex()], STAGED_AT)
                    .await
                    .expect("the removal is staged")
                    .fanouts,
            )
        } else {
            stage_eviction_recorded(&admin, &others[1], &group, STAGED_AT).await
        };
        let event = row(&admin, &id).await.event_id;
        // One relay cannot be reached; the other answers "not now".
        let transport = answering(&[(ONE, &[Answer::Unreachable]), (TWO, &[Answer::RateLimited])]);
        let clock = Clock::at(0);
        let mut lines = Vec::new();
        for at in [0, DAY_MS - 1, DAY_MS, 2 * DAY_MS, 30 * DAY_MS] {
            clock.set(at);
            let mut outcome = None;
            lines.extend(
                capture_haven_log(async {
                    outcome = Some(drive(&admin, &transport, &clock, &id).await);
                })
                .await,
            );
            let outcome = outcome.expect("ran");
            assert_eq!(
                outcome.status,
                FanoutStatus::Unresolved,
                "a removal was resolved with no relay's answer ({at} ms, own remove: {own_remove})",
            );
            assert!(outcome.notes.is_empty());
        }
        assert!(
            lines
                .iter()
                .all(|line| !line.message.contains("was undone")),
            "a removal was said to be undone",
        );
        let kept = row(&admin, &id).await;
        assert_eq!(kept.mls, FanoutMls::Pending);
        assert_eq!(
            kept.statuses,
            [FanoutTargetStatus::RetryableUnavailable; 2],
            "a removal's relays were ended at the bound",
        );
        assert!(
            staged_ref(&admin, &group).await.is_some()
                && commit_state(&admin, event).await == Some(MessageState::Sent),
            "a removal no relay could be reached for was undone (own remove: {own_remove})",
        );
        assert!(
            !can_send(&admin, &group).await,
            "a location left for a circle whose removal is still pending",
        );
        assert!(admin.session().take_change_notes(&group).is_empty());
        assert!(
            transport.calls().len() >= 2 * 4,
            "premise: its relays were still being asked",
        );

        // The next process knows no more and no less.
        let admin = admin.reopen();
        clock.set(60 * DAY_MS);
        assert_eq!(
            drive(&admin, &transport, &clock, &id).await.status,
            FanoutStatus::Unresolved,
            "a removal restored after a restart was undone at the bound",
        );
        assert!(staged_ref(&admin, &group).await.is_some() && !can_send(&admin, &group).await);

        // A relay that answers applies it.
        transport.answer(ONE, [Answer::Accepted]);
        clock.set(61 * DAY_MS);
        assert_eq!(
            drive(&admin, &transport, &clock, &id).await.status,
            FanoutStatus::Confirmed
        );
        assert_eq!(settled_members(&admin, &group).await, Some(2));
    }
}

/// What may be undone at the bound is known from a mark written in the hold
/// that staged the commit, and from nothing else. A change that removes
/// nobody keeps the mark across a restart; a commit recorded without one —
/// here handed to the staging step from another call — is treated as one
/// that may remove a member, and is never undone.
#[tokio::test]
async fn only_a_commit_marked_as_removing_nobody_is_undone_and_the_mark_survives_a_restart() {
    // Marked, and restarted before the bound.
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let id = stage_relay_change(&admin, &group, &[ONE, TWO]).await;
    let transport = answering(&[(ONE, &[Answer::Unreachable])]);
    let clock = Clock::at(0);
    let _ = drive(&admin, &transport, &clock, &id).await;
    let admin = admin.reopen();
    clock.set(DAY_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::RolledBack,
        "a change that removes nobody lost its standing across a restart",
    );

    // The same change, recorded without the mark.
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let staged = admin
        .session()
        .update_relays(&group, vec![ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change is staged the legacy way");
    let id = the_one(
        admin
            .session()
            .stage_commits_for_test(staged, STAGED_AT)
            .await
            .fanouts,
    );
    let clock = Clock::at(0);
    for at in [0, DAY_MS, 3 * DAY_MS] {
        clock.set(at);
        assert_eq!(
            drive(&admin, &transport, &clock, &id).await.status,
            FanoutStatus::Unresolved,
            "a commit nothing showed to remove nobody was undone at the bound",
        );
    }
    assert!(staged_ref(&admin, &group).await.is_some());
}

/// A removal every relay proved it refused is still undone — and that is
/// said, as a fixed note that survives the drive and the process, whoever
/// was or was not waiting for the answer, and is handed over once.
#[tokio::test]
async fn a_removal_every_relay_refused_is_undone_and_the_circle_is_told_once() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let id = stage_removal(&fx).await;
    let (admin, _others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    let outcome = drive(&admin, &transport, &Clock::at(0), &id).await;
    assert_eq!(outcome.status, FanoutStatus::RolledBack);
    assert_eq!(
        outcome.notes,
        [ChangeNote::RemovalUndone],
        "an undone removal was not said to be one",
    );
    assert_eq!(settled_members(&admin, &group).await, Some(3));

    // Nobody read it; the process ends; the next one still has it.
    let admin = admin.reopen();
    assert_eq!(
        admin.session().take_change_notes(&group),
        [ChangeNote::RemovalUndone],
        "what a drive undid was lost with the process",
    );
    assert!(admin.session().take_change_notes(&group).is_empty());
}

// ── A finished record does not restart a relay's schedule ────────────────────

/// Two records owe one failing relay. The first has made eleven unanswered
/// calls to it — the relay is at its longest wait — when the second is
/// staged. When the first reaches its end it makes no further call, and it
/// is KEPT: deleting it would take its eleven calls off the relay's record
/// and have the second's single call start the schedule over. The relay goes
/// on being called once an hour, across a restart, and the first record is
/// deleted only once the second's own calls have reached the longest wait.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_relays_back_off_does_not_restart_when_a_record_that_owed_it_ends() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    // TWO takes the socket and never answers.
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Silent])]);
    let clock = Clock::at(0);
    let first = stage_relay_change(&admin, &group, &[ONE, TWO, THREE]).await;
    let first_event = row(&admin, &first).await.event_id;
    for hour in 0..11 {
        clock.set(hour * HOUR_MS);
        assert_eq!(
            drive(&admin, &transport, &clock, &first).await.status,
            FanoutStatus::Confirmed
        );
    }
    assert_eq!(
        row(&admin, &first).await.attempts[1],
        11,
        "premise: eleven unanswered calls to the relay",
    );
    // A second circle's removal, frozen for that relay alone: pending, and
    // possibly exposed from its first call on.
    let elsewhere = solo_circle(&admin, &[TWO]).await;
    let second = stage_relay_change(&admin, &elsewhere, &[TWO, THREE]).await;
    let second_event = row(&admin, &second).await.event_id;
    clock.set(10 * HOUR_MS + 60 * SECOND_MS);
    let _ = drive(&admin, &transport, &clock, &second).await;
    assert_eq!(row(&admin, &second).await.attempts, [1]);
    transport.calls();

    // Every minute from the first record's end, a day after its first
    // acknowledgement, for three hours — with the process restarted half way.
    let mut admin = admin;
    let mut second_calls: Vec<u64> = Vec::new();
    let end = DAY_MS;
    let mut at = end;
    while at < end + 3 * HOUR_MS {
        if at == end + 90 * 60 * SECOND_MS {
            admin = admin.reopen();
        }
        clock.set(at);
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
        for call in transport.calls() {
            assert_ne!(
                call.event_id, first_event,
                "a record that had ended made a call ({at} ms)",
            );
            assert_eq!((call.target.as_str(), call.event_id), (TWO, second_event));
            second_calls.push(at);
        }
        at += 60 * SECOND_MS;
    }
    for hour in 0..3 {
        let calls = second_calls
            .iter()
            .filter(|at| **at >= end + hour * HOUR_MS && **at < end + (hour + 1) * HOUR_MS)
            .count();
        assert!(
            calls <= 1,
            "{calls} calls to a failing relay in one hour after a record that owed it ended",
        );
    }
    assert!(
        !second_calls.is_empty(),
        "premise: the relay was still being called for the record that remained",
    );
    assert!(
        probe(&admin, &first).await.is_some(),
        "the finished record was deleted while that would have restarted the relay's schedule",
    );

    // Hourly until the second record's own calls have earned the longest
    // wait: from then on the first changes nothing, and goes.
    while row(&admin, &second).await.attempts[0] < 8 {
        at += HOUR_MS;
        clock.set(at);
        let _ = drive_due(
            &admin.circle,
            &transport,
            &clock,
            None,
            None,
            &DriveMode::Full,
        )
        .await;
    }
    at += HOUR_MS;
    clock.set(at);
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
        probe(&admin, &first).await.is_none(),
        "a finished record outlived the last wait it was holding up",
    );
    assert!(transport
        .calls()
        .iter()
        .all(|call| call.event_id == second_event));
}

/// A relay that takes a newer commit is there. The older commit it still
/// owes follows in the same pass, in staging order, instead of waiting out a
/// back-off the relay has just shown to be over.
#[tokio::test]
async fn a_relay_that_takes_a_newer_commit_is_sent_the_older_one_it_owes_in_the_same_pass() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Unreachable])]);
    let clock = Clock::at(0);
    // The older commit moves the circle to the second relay alone. The
    // first relay takes it; the second cannot be reached, four times over.
    let older = stage_relay_change(admin, &fx.group, &[TWO]).await;
    let older_event = row(admin, &older).await.event_id;
    for at in [0, 5, 10, 15] {
        clock.set(at * SECOND_MS);
        let _ = drive(admin, &transport, &clock, &older).await;
    }
    assert_eq!(row(admin, &older).await.attempts[1], 4);
    transport.calls();

    // The newer commit is frozen for that second relay alone, which is back.
    let newer = stage_removal(&fx).await;
    let newer_event = row(admin, &newer).await.event_id;
    assert_eq!(row(admin, &newer).await.targets, [TWO]);
    transport.answer(TWO, [Answer::Accepted]);
    clock.set(16 * SECOND_MS);
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        Some(&fx.group),
        None,
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none());
    let sent: Vec<(String, nostr::EventId)> = transport
        .calls()
        .into_iter()
        .map(|call| (call.target, call.event_id))
        .collect();
    assert_eq!(
        sent,
        [
            (TWO.to_string(), newer_event),
            (TWO.to_string(), older_event)
        ],
        "a relay that had just taken a commit was not sent the older one it still owed",
    );
    // Both have nothing left to do; the newer one's record goes at its next
    // drive, having been kept only as what showed the relay to be back.
    assert!(probe(admin, &older).await.is_none());
    let due = drive_due(
        &admin.circle,
        &transport,
        &clock,
        Some(&fx.group),
        None,
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none() && transport.calls().is_empty());
    assert!(probe(admin, &newer).await.is_none());
}

/// Two circles' commits wait on one relay that cannot be reached. Following
/// the wake each pass asks for, on the clock alone: every wake has a call to
/// make, none is asked for "now" while nothing can be done, and the second
/// circle's commit is retried on the relay's one schedule.
#[tokio::test]
async fn two_circles_on_one_failing_relay_are_woken_on_the_relays_one_schedule() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let first = stage_removal_of(&admin, &group).await;
    let elsewhere = solo_circle(&admin, &[ONE]).await;
    let second = stage_relay_change(&admin, &elsewhere, &[ONE, TWO]).await;
    let (first_event, second_event) = (
        row(&admin, &first).await.event_id,
        row(&admin, &second).await.event_id,
    );
    let transport = answering(&[(ONE, &[Answer::Unreachable])]);
    let clock = Clock::at(0);

    let mut now = 0;
    let mut calls: Vec<(u64, nostr::EventId)> = Vec::new();
    for wake in 0..14 {
        clock.set(now);
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
        let made = transport.calls();
        assert!(
            !made.is_empty(),
            "wake {wake} at {now} ms had nothing to do: the hint before it was wrong",
        );
        calls.extend(made.iter().map(|call| (now, call.event_id)));
        let hint = due
            .retry_after_ms
            .expect("two pending commits on a failing relay ask to be woken");
        assert!(
            hint > 0,
            "a wake was asked for at once with every relay waiting"
        );
        now += hint;
    }
    assert!(now < DAY_MS, "premise: before either commit's bound");
    // Each commit's first call is its own; after that the relay is called
    // once per wait, alternately for whichever commit is taken up first.
    assert_eq!(
        calls.iter().filter(|(at, _)| *at == 0).count(),
        2,
        "premise: each commit's first call",
    );
    let later: Vec<u64> = calls
        .iter()
        .filter(|(at, _)| *at > 0)
        .map(|(at, _)| *at)
        .collect();
    assert!(
        later.windows(2).all(|pair| pair[1] > pair[0]),
        "two calls were made to a failing relay in one wake",
    );
    assert!(
        calls
            .iter()
            .any(|(at, event)| *at > 0 && *event == second_event)
            && calls
                .iter()
                .any(|(at, event)| *at > 0 && *event == first_event),
        "one circle's commit was never retried on the relay the two share",
    );
}

/// What one relay is sent, minute by minute, when two circles' commits both
/// wait on it and it keeps failing one way: the calls of its first hour, and
/// then never more than one an hour. The device wakes once a minute for three
/// hours and drives whatever is due.
async fn calls_to_a_failing_relay_two_commits_wait_on(how: Answer) -> Vec<u64> {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let _first = stage_removal_of(&admin, &group).await;
    let elsewhere = solo_circle(&admin, &[ONE]).await;
    let _second = stage_relay_change(&admin, &elsewhere, &[ONE, TWO]).await;
    let transport = answering(&[(ONE, &[how])]);
    let clock = Clock::at(0);
    let mut calls = Vec::new();
    let mut at = 0;
    while at < 3 * HOUR_MS {
        clock.set(at);
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
        calls.extend(transport.calls().iter().map(|_| at));
        at += 60 * SECOND_MS;
    }
    for hour in 1..3 {
        let in_hour = calls
            .iter()
            .filter(|at| **at >= hour * HOUR_MS && **at < (hour + 1) * HOUR_MS)
            .count();
        assert!(
            in_hour <= 1,
            "{in_hour} calls to a failing relay in hour {}",
            hour + 1
        );
    }
    assert!(
        calls.iter().any(|at| *at >= HOUR_MS),
        "premise: the relay is still being tried after its first hour",
    );
    calls
}

/// A relay that cannot be reached, with two commits waiting on it and the
/// device waking every minute: each commit's own first call, then the
/// relay's one schedule — never the schedule once per commit.
#[tokio::test]
async fn an_unreachable_relay_two_commits_wait_on_is_called_on_one_schedule_minute_by_minute() {
    let calls = calls_to_a_failing_relay_two_commits_wait_on(Answer::Unreachable).await;
    let minutes: Vec<u64> = calls.iter().map(|at| at / (60 * SECOND_MS)).collect();
    // Minute 0 twice: each commit's own first call. Then five seconds three
    // times — a minute each, at this cadence — and thirty seconds doubling.
    assert_eq!(
        minutes,
        [0, 0, 1, 2, 3, 4, 6, 10, 18, 34, 66, 126],
        "the minutes a relay that cannot be reached was called at",
    );
    assert_eq!(
        calls.iter().filter(|at| **at < HOUR_MS).count(),
        10,
        "calls to an unreachable relay in its first hour, two commits waiting",
    );
}

/// The same for a relay that answers `rate-limited:`. Its waits carry a
/// spread taken from the commit's own id, so the minutes differ from run to
/// run and the count does not.
#[tokio::test]
async fn a_rate_limiting_relay_two_commits_wait_on_is_called_on_one_schedule_minute_by_minute() {
    let calls = calls_to_a_failing_relay_two_commits_wait_on(Answer::RateLimited).await;
    assert_eq!(
        calls.iter().filter(|at| **at == 0).count(),
        2,
        "premise: each commit's own first call",
    );
    // After those, waits of two minutes doubling, each stretched by up to a
    // quarter: four more calls inside the hour whatever the spread, the next
    // one after it.
    assert_eq!(
        calls.iter().filter(|at| **at < HOUR_MS).count(),
        6,
        "calls to a rate-limiting relay in its first hour, two commits waiting",
    );
    let later: Vec<u64> = calls.iter().copied().filter(|at| *at > 0).collect();
    assert!(
        later
            .windows(2)
            .all(|pair| pair[1] - pair[0] >= 2 * 60 * SECOND_MS),
        "a rate-limiting relay was called twice within two minutes",
    );
}

/// Stages the removal of `group`'s last member by `admin`.
async fn stage_removal_of(admin: &CircleMember, group: &GroupId) -> FanoutId {
    let members = admin
        .session()
        .member_pubkeys(group)
        .await
        .expect("the roster");
    let last = members
        .into_iter()
        .rfind(|member| *member != admin.pubkey_hex())
        .expect("a member besides the admin");
    the_one(
        admin
            .session()
            .remove_members_staging(group, &[last], STAGED_AT)
            .await
            .expect("the removal is staged")
            .fanouts,
    )
}

/// The exposure FLAG decides whether a pending commit may be undone at the
/// bound, whatever its targets' statuses read: a stored record whose every
/// target says "could not be reached" beside a set flag is never ended by
/// the bound, on a clock at or far past it, in the process that reads it
/// back from the store.
#[tokio::test]
async fn a_stored_record_flagged_as_exposed_is_never_bounded_whatever_its_statuses_say() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let id = stage_relay_change(&admin, &group, &[ONE, TWO]).await;
    let transport = answering(&[(ONE, &[Answer::Unreachable])]);
    // Its relay is asked two seconds before the bound, so that it is not
    // due again when the bound is reached.
    let clock = Clock::at(DAY_MS - 2 * SECOND_MS);
    let _ = drive(&admin, &transport, &clock, &id).await;
    let (admin, _) = reopen_after(admin, StoreEdit::FlagEveryFanoutExposed).await;
    assert_eq!(
        row(&admin, &id).await.statuses,
        [FanoutTargetStatus::RetryableUnavailable],
        "premise: the status reads as never exposed",
    );
    transport.calls();

    clock.set(DAY_MS);
    let mut status = None;
    let lines = capture_haven_log(async {
        status = Some(drive(&admin, &transport, &clock, &id).await.status);
    })
    .await;
    assert_eq!(status, Some(FanoutStatus::Unresolved));
    assert_eq!(transport.calls().len(), 0, "premise: the relay is not due");
    assert_eq!(
        row(&admin, &id).await.statuses,
        [FanoutTargetStatus::RetryableUnavailable],
        "the bound ended a target of a record flagged as possibly exposed",
    );
    assert!(lines
        .iter()
        .all(|line| !line.message.contains("was undone")));

    // However long after, and whatever its relay answers.
    clock.set(3 * DAY_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Unresolved
    );
    assert_ne!(
        row(&admin, &id).await.statuses,
        [FanoutTargetStatus::Failed]
    );
    assert!(staged_ref(&admin, &group).await.is_some());
}

// ── A rolled-back commit is retired before the engine is asked anything ──────

/// MDK's rollback rewinds a commit and leaves its own stored row as sent,
/// where the circle's next convergence pass would merge it — a commit every
/// relay refused, applied on this device alone. Haven retires that row right
/// after the rewind. When that write fails, every call that could run such a
/// pass is refused until it has landed, in this process and in the next; the
/// first call after it can land retires the row before the engine is asked.
#[tokio::test]
async fn a_rolled_back_commit_not_yet_retired_is_retired_before_any_engine_call() {
    let fx = setup_circle(3, &[ONE]).await;
    let before = fx.admin().session().epoch(&fx.group).await.expect("epoch");
    let id = stage_removal(&fx).await;
    let (admin, others, group) = split(fx);
    let event = row(&admin, &id).await.event_id;
    let (db, key) = db_of(&admin);
    let peer_fix = location_from(&others[0], &group)
        .await
        .expect("a peer seals a location");
    let refusing = answering(&[(ONE, &[Answer::Refused])]);

    set_commit_retirement_fault_for_test(&db, &key, event.as_bytes(), true).expect("arm");
    assert_eq!(
        drive(&admin, &refusing, &Clock::at(0), &id).await.status,
        FanoutStatus::RolledBack
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && commit_state(&admin, event).await == Some(MessageState::Sent)
            && probe(&admin, &id).await.is_some(),
        "premise: rewound, and neither retired nor forgotten",
    );

    // Nothing that could merge it is let through to the engine.
    let other = [others[1].pubkey_hex()];
    let lines = Box::pin(capture_haven_log(async {
        assert!(admin.session().advance_for_receive(&group).await.is_err());
        assert!(admin.session().advance_convergence(&group).await.is_err());
        assert!(admin
            .session()
            .remove_members(&group, &other)
            .await
            .is_err());
        assert!(admin.circle.ingest_for_test(&peer_fix).await.is_err());
        assert!(!can_send(&admin, &group).await);
        assert!(admin.session().receive_retick_after(&group).await.is_none());
    }))
    .await;
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "is not yet retired")),
        &[&hex::encode(group.as_slice()), &event.to_hex(), CANARY],
    );
    assert_eq!(commit_state(&admin, event).await, Some(MessageState::Sent));
    // What only reads is not refused.
    assert_eq!(admin.session().epoch(&group).await.expect("epoch"), before);

    // The next process, with the write still failing: the same.
    let admin = admin.reopen();
    assert!(admin.session().advance_for_receive(&group).await.is_err());
    assert!(!can_send(&admin, &group).await);
    assert_eq!(commit_state(&admin, event).await, Some(MessageState::Sent));

    // Once it can be written, the first call of any plane retires it first.
    set_commit_retirement_fault_for_test(&db, &key, event.as_bytes(), false).expect("disarm");
    serve_deadlines(&admin, &group).await;
    assert_eq!(
        commit_state(&admin, event).await,
        Some(MessageState::Failed),
        "a rolled-back commit was not retired before the engine was asked to advance its circle",
    );
    assert!(probe(&admin, &id).await.is_none());
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before,
        "a commit every relay refused was merged",
    );
    assert_eq!(settled_members(&admin, &group).await, Some(3));
    assert!(can_send(&admin, &group).await);
}

// ── The engine's own commit is not staged again on every pass ────────────────

/// An eviction every relay refuses — a device whose clock is wrong is told
/// `invalid:` by each — is staged again by the engine on its next pass, and
/// would be sent to every relay and rolled back on every pass after that.
/// Instead each rollback earns the circle a wait, a minute then doubling,
/// inside which the commit the engine stages again is undone in the hold
/// that staged it: nothing recorded, nothing sent. The epoch moving ends it.
#[tokio::test]
async fn an_eviction_every_relay_refuses_is_staged_again_on_a_doubling_schedule_not_every_pass() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Invalid])]);
    let clock = Clock::at(0);
    let first = stage_eviction_recorded(&admin, &others[1], &group, clock.now_ms()).await;
    let outcome = drive(&admin, &transport, &clock, &first).await;
    assert_eq!(outcome.status, FanoutStatus::RolledBack);
    assert_eq!(outcome.notes, [ChangeNote::RemovalUndone]);
    assert_eq!(transport.calls().len(), 1);

    let mut rolled_back_at = 0;
    for wait in [60 * SECOND_MS, 120 * SECOND_MS, 240 * SECOND_MS] {
        // A millisecond inside the wait: pass after pass stages it again,
        // and each time it is undone unsent.
        clock.set(rolled_back_at + wait - 1);
        let mut recorded = None;
        let lines = capture_haven_log(async {
            recorded = restage_eviction(&admin, &group, clock.now_ms()).await;
        })
        .await;
        assert!(
            recorded.is_none(),
            "an eviction every relay had just refused was recorded again inside its wait",
        );
        assert_no_needles(
            std::slice::from_ref(line_saying(&lines, "is undone unsent")),
            &[
                &hex::encode(group.as_slice()),
                &others[1].pubkey_hex(),
                CANARY,
            ],
        );
        assert!(
            lines
                .iter()
                .filter(|line| line.message.contains("is undone unsent"))
                .count()
                >= 2,
            "premise: more than one pass staged it inside the wait",
        );
        assert!(rows_of(&admin, &group).await.is_empty());
        assert!(staged_ref(&admin, &group).await.is_none());
        assert_eq!(
            transport.call_count(),
            0,
            "a relay was sent an eviction inside the wait its refusal earned",
        );

        // The wait over: recorded, sent once, refused again.
        clock.set(rolled_back_at + wait);
        let again = restage_eviction(&admin, &group, clock.now_ms())
            .await
            .expect("the eviction is staged again once its wait is over");
        assert_eq!(
            drive(&admin, &transport, &clock, &again).await.status,
            FanoutStatus::RolledBack
        );
        assert_eq!(transport.calls().len(), 1);
        rolled_back_at += wait;
    }

    // A relay takes it: applied, and the next change is not held.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(rolled_back_at + 480 * SECOND_MS);
    let taken = restage_eviction(&admin, &group, clock.now_ms())
        .await
        .expect("staged again");
    assert_eq!(
        drive(&admin, &transport, &clock, &taken).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(settled_members(&admin, &group).await, Some(2));
}

// ── A commit a resolution hands back ─────────────────────────────────────────

/// A resolution's engine call collects whatever the engine holds emitted,
/// and that can be a commit some earlier call staged and never handed over.
/// It is given its record in the resolution's own hold and driven in the
/// same pass — though the pass was asked for another circle's records.
#[tokio::test]
async fn a_commit_a_resolution_hands_back_is_recorded_and_driven_in_the_same_pass() {
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let _first = stage_removal(&fx).await;
    let other = solo_circle(admin, &[TWO]).await;
    let left = admin
        .session()
        .update_relays(&other, vec![THREE.to_string()])
        .await
        .expect("another circle's change is staged, and no record written");
    let left_event = commit_event_id(&left);
    // As the engine's one-shot buffer holds what a call that failed after
    // staging left in it.
    admin.session().strand_effects_for_test(left);

    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let due = drive_due(
        &admin.circle,
        &transport,
        &Clock::at(0),
        Some(&fx.group),
        None,
        &DriveMode::Full,
    )
    .await;
    assert!(due.error.is_none());
    assert_eq!(
        due.driven
            .iter()
            .map(|(_, outcome)| (outcome.status, outcome.staged.len()))
            .collect::<Vec<_>>(),
        [(FanoutStatus::Confirmed, 1), (FanoutStatus::Confirmed, 0)],
        "a commit the resolution handed back was not driven in the pass that recorded it",
    );
    let sent = transport.calls();
    assert_eq!(
        sent.last()
            .map(|call| (call.target.as_str(), call.event_id)),
        Some((TWO, left_event))
    );
    assert!(staged_ref(admin, &other).await.is_none());
    assert_eq!(
        admin.session().group_relays(&other).await.expect("relays"),
        [THREE]
    );
}

// ── A repaired record's relays each get a real attempt ───────────────────────

/// A record the open wrote for a commit it found staged says each relay MAY
/// hold the commit; none of them has been asked under it. A relay that was
/// not free when the first drive ran is still owed that attempt a day later,
/// and the record does not end before it has been made.
#[tokio::test]
async fn a_repaired_records_relay_is_asked_before_the_record_ends() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let commit = commit_event_id(
        &admin
            .session()
            .remove_members(&group, &[others[1].pubkey_hex()])
            .await
            .expect("a removal is staged, and no record written"),
    );
    let admin = admin.reopen();
    let id = the_one(rows_of(&admin, &group).await);
    let transport = answering(&[
        (ONE, &[Answer::Accepted]),
        (TWO, &[Answer::Unreachable]),
        (THREE, &[Answer::Silent]),
    ]);
    let clock = Clock::at(0);
    // Another circle's commit has just failed to reach the second relay.
    let elsewhere = failing_elsewhere(&admin, &[TWO, THREE], &transport, &clock).await;
    transport.calls();
    clock.set(SECOND_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        calls_to(&transport.calls(), TWO, commit),
        0,
        "premise: the second relay was backing off when the commit was applied",
    );

    // A day on, that relay having failed the other circle a moment before.
    clock.set(DAY_MS + 2 * SECOND_MS);
    let _ = drive(&admin, &transport, &clock, &elsewhere).await;
    transport.calls();
    clock.set(DAY_MS + 3 * SECOND_MS);
    let _ = drive(&admin, &transport, &clock, &id).await;
    assert_eq!(transport.calls().len(), 0, "premise: the relay is not due");
    assert!(probe(&admin, &id).await.is_some());

    clock.set(DAY_MS + 2 * HOUR_MS);
    let _ = drive(&admin, &transport, &clock, &id).await;
    assert_eq!(
        calls_to(&transport.calls(), TWO, commit),
        1,
        "a repaired record ended without one of its relays ever being asked",
    );
}

// ── A commit applied here that no relay holds, once it has lost ──────────────

/// A record Haven itself marked applied — the engine had applied the commit
/// by another path — with no relay holding the commit and none that may: if
/// the commit then loses to a rival branch, sending it would hand the circle
/// a rival this device has itself set aside. While the loss is provisional
/// nothing is sent and the record is kept; once it is final the record ends
/// unsent.
#[tokio::test]
async fn an_applied_commit_no_relay_holds_is_not_sent_once_it_has_lost() {
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let (admin, _others, group) = split(fx);
    let event = row(&admin, &id).await.event_id;
    // Applied by another path, its record still pending; then every relay
    // out of reach, so the record is marked applied with nothing sent.
    let pending = staged_ref(&admin, &group).await.expect("staged");
    admin
        .session()
        .confirm_published_past_its_fanout_for_test(pending)
        .await
        .expect("the commit is applied past its record");
    let transport = answering(&[(ONE, &[Answer::Unreachable])]);
    let clock = Clock::at(0);
    let _ = drive(&admin, &transport, &clock, &id).await;
    let kept = row(&admin, &id).await;
    assert_eq!(
        (kept.mls, kept.statuses.as_slice()),
        (
            FanoutMls::Confirmed,
            [FanoutTargetStatus::RetryableUnavailable].as_slice()
        ),
        "premise: applied, no relay holds it and none may",
    );
    transport.calls();
    transport.answer(ONE, [Answer::Accepted]);

    // Set aside, for now.
    let (admin, _) = reopen_after(
        admin,
        StoreEdit::MessageState {
            id: event.as_bytes(),
            state: MessageState::ConvergenceDeferred,
        },
    )
    .await;
    clock.set(HOUR_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert_eq!(
        transport.calls().len(),
        0,
        "a commit this device had set aside was sent to a relay",
    );
    assert!(probe(&admin, &id).await.is_some());

    // Set aside for good.
    let (admin, _) = reopen_after(
        admin,
        StoreEdit::MessageState {
            id: event.as_bytes(),
            state: MessageState::EpochInvalidated,
        },
    )
    .await;
    clock.set(2 * HOUR_MS);
    assert_eq!(
        drive(&admin, &transport, &clock, &id).await.status,
        FanoutStatus::Stale
    );
    assert_eq!(transport.calls().len(), 0);
    assert!(
        probe(&admin, &id).await.is_none() && !is_owned(&event),
        "the record of a commit that lost for good, which no relay holds, was kept",
    );
}

/// The driver reads a record as one the engine no longer holds and nothing
/// was sent under, and only then takes the hold that abandons it. A pass
/// that applied the commit in between must not cost it its record: applied
/// here, it is still owed to its relays.
#[tokio::test]
async fn a_record_abandoned_as_unsent_is_kept_when_its_commit_was_applied_meanwhile() {
    let fx = setup_circle(3, &[ONE]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    admin
        .session()
        .confirm_published_past_its_fanout_for_test(pending)
        .await
        .expect("the commit is applied between the driver's read and its hold");

    assert!(admin
        .session()
        .abandon_unsent_fanout_for_test(&id)
        .await
        .expect("the store is written"));
    assert_eq!(
        probe(admin, &id).await.map(|row| row.mls),
        Some(FanoutMls::Confirmed),
        "a commit applied on this device lost the record of what it still owes its relays",
    );
    assert_eq!(
        commit_state(admin, event).await,
        Some(MessageState::Processed)
    );
}

// ── The finishing confirm ────────────────────────────────────────────────────

/// The plain confirm that finishes a commit the store has applied is asked
/// again in the same drive for a store that was busy, four asks in all, as
/// MDK's host asks; for any other error it is asked once.
#[tokio::test]
async fn the_finishing_confirm_is_asked_again_only_for_a_busy_store_and_four_times_in_all() {
    for (faults, finished, left) in [
        (&[true][..], true, 0),
        (&[true, true, true, true, true][..], false, 1),
        (&[false, true][..], false, 1),
    ] {
        let fx = setup_circle(2, &[ONE]).await;
        let admin = fx.admin();
        let (db, key) = db_of(admin);
        let source = admin.session().epoch(&fx.group).await.expect("epoch");
        let id = stage_relay_change(admin, &fx.group, &[ONE, TWO]).await;
        let transport = answering(&[(ONE, &[Answer::Accepted])]);
        let clock = Clock::at(0);
        set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
        let _ = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full).await;
        set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
        assert!(
            staged_ref(admin, &fx.group).await.is_some()
                && row(admin, &id).await.mls == FanoutMls::Confirmed,
            "premise: applied in the store, the engine still holding the commit",
        );

        admin.session().fail_next_confirms_for_test(faults);
        clock.set(SECOND_MS);
        let outcome = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .unwrap_or_else(|_| panic!("an applied commit was reported as an error"));
        assert_eq!(outcome.status, FanoutStatus::Confirmed);
        assert_eq!(
            (
                outcome.error.is_none(),
                admin.session().confirm_faults_left_for_test()
            ),
            (finished, left),
            "the finishing confirm was not asked as MDK's host asks it ({faults:?})",
        );
        assert_eq!(staged_ref(admin, &fx.group).await.is_none(), finished);
    }
}

// ── Rows of a circle that is no longer live ──────────────────────────────────

/// A record of a circle this device has since forgotten can never be deleted
/// through the engine. It is found by every pass, and costs it a read: no
/// relay is ever called for it, and it is no error.
#[tokio::test]
async fn a_record_of_a_circle_that_is_no_longer_live_makes_no_call() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_relay_change(admin, &fx.group, &[ONE]).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Unreachable])]);
    let clock = Clock::at(0);
    assert_eq!(
        drive(admin, &transport, &clock, &id).await.status,
        FanoutStatus::Confirmed
    );
    assert!(probe(admin, &id).await.is_some(), "premise: still owed");
    transport.calls();
    admin
        .session()
        .forget_group_local(&fx.group)
        .await
        .expect("the circle is forgotten");

    for hours in [1, 5, 48] {
        clock.set(hours * HOUR_MS);
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
        assert!(due
            .driven
            .iter()
            .all(|(_, outcome)| outcome.status == FanoutStatus::Gone));
    }
    assert_eq!(
        transport.calls().len(),
        0,
        "a relay was called for a circle this device had forgotten",
    );
}

// ── A send beside a commit a relay may hold that is no longer staged ─────────

/// A record whose commit a relay may hold and the engine no longer stages
/// takes no new change of its circle beside it. A location send is not a
/// change, and with a leave received and its eviction due, nothing the
/// foreground's send does stages that eviction beside the record: MDK's
/// preflight stages none while an outbound fanout it retries stands, and
/// one any call did stage there is undone in the hold that staged it
/// (`fanout_driver_e2e::a_call_that_makes_no_commit_hands_on_none_staged_beside_a_pending_row_a_relay_may_hold`).
#[tokio::test]
async fn a_send_never_leaves_an_eviction_staged_beside_a_commit_a_relay_may_hold() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let admin = fx.admin();
    let id = stage_removal(&fx).await;
    let event = row(admin, &id).await.event_id;
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
    let _ = drive(admin, &transport, &Clock::at(0), &id).await;
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    let (db, key) = db_of(admin);
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && commit_state(admin, event).await == Some(MessageState::Sent),
        "premise: a relay may hold the commit, and the engine no longer stages it",
    );

    // Another member leaves. Nothing asks the engine for the circle's
    // deadline or advances it: only the eviction's own delay is waited out.
    let leave = fx.members[1]
        .session()
        .leave_group(&fx.group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let proposal = SessionManager::proposal_events(&leave.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    let _ = admin
        .session()
        .process_event(&proposal)
        .await
        .expect("ingest");
    for _ in 0..8 {
        if let Some(wait) = admin.session().eviction_due_after_for_test(&fx.group).await {
            tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
        }
        assert!(
            admin
                .session()
                .eviction_due_after_for_test(&fx.group)
                .await
                .is_some(),
            "premise: the eviction is due as the send is made",
        );
        let _ = full_location_from(admin, &fx.group).await;
        assert!(
            staged_ref(admin, &fx.group).await.is_none(),
            "a send left an eviction staged beside a commit a relay may hold",
        );
    }
    assert_eq!(
        rows_of(admin, &fx.group).await,
        std::slice::from_ref(&id),
        "the record of the commit a relay may hold was replaced or joined",
    );
    assert_eq!(commit_state(admin, event).await, Some(MessageState::Sent));
    assert_eq!(row(admin, &id).await.mls, FanoutMls::Pending);
}

// ── A commit a relay may hold that ended for good without being applied ──────

/// A commit a relay may hold is one the rest of the circle may have applied.
/// When the engine gives it a final state without this device ever applying
/// it, the device may be left behind — sealing at an epoch the others have
/// left, readable by whoever that commit removed. Its record is not deleted
/// in silence: the circle is noted as possibly out of step, durably, and one
/// line says so that names nothing — whether a drive finds it or an open.
#[tokio::test]
async fn a_commit_a_relay_may_hold_that_ends_for_good_leaves_its_circle_told_it_may_be_out_of_step()
{
    for found_by_the_open in [false, true] {
        let fx = setup_circle(3, &[ONE]).await;
        let id = stage_removal(&fx).await;
        let (admin, _others, group) = split(fx);
        let event = row(&admin, &id).await.event_id;
        let transport = answering(&[(ONE, &[Answer::Silent])]);
        let clock = Clock::at(0);
        let _ = drive(&admin, &transport, &clock, &id).await;
        transport.calls();
        // No longer staged, and still stored as sent: the unheld record.
        let pending = staged_ref(&admin, &group).await.expect("staged");
        let (db, key) = db_of(&admin);
        set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
        let _ = admin
            .session()
            .publish_failed_past_its_fanout_for_test(pending)
            .await;
        set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
        assert_eq!(commit_state(&admin, event).await, Some(MessageState::Sent));

        // The engine sets the commit aside for good.
        let lost = StoreEdit::MessageState {
            id: event.as_bytes(),
            state: MessageState::EpochInvalidated,
        };
        let (admin, lines) = if found_by_the_open {
            reopen_after(admin, lost).await
        } else {
            // Edited under a pass before the open that cannot delete the
            // record, so that it is the first drive that finds it.
            set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, true)
                .expect("arm");
            let (admin, _) = reopen_after(admin, lost).await;
            set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutDelete, false)
                .expect("disarm");
            assert!(probe(&admin, &id).await.is_some(), "premise: still stored");
            let mut status = None;
            let lines = capture_haven_log(async {
                status = Some(drive(&admin, &transport, &clock, &id).await.status);
            })
            .await;
            assert_eq!(status, Some(FanoutStatus::Stale));
            (admin, lines)
        };
        assert_no_needles(
            std::slice::from_ref(line_saying(&lines, "may be out of step")),
            &[&hex::encode(group.as_slice()), &event.to_hex(), CANARY],
        );
        assert!(probe(&admin, &id).await.is_none());
        assert_eq!(transport.calls().len(), 0);
        assert_eq!(
            admin.session().take_change_notes(&group),
            [ChangeNote::MayBeOutOfStep],
            "the circle was not told (found by the open: {found_by_the_open})",
        );
    }

    // A record nothing was ever sent under says nothing of the kind.
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let (admin, _others, group) = split(fx);
    let event = row(&admin, &id).await.event_id;
    let pending = staged_ref(&admin, &group).await.expect("staged");
    admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await
        .expect("discarded past its record");
    assert_eq!(
        commit_state(&admin, event).await,
        Some(MessageState::Failed)
    );
    let mut status = None;
    let lines = capture_haven_log(async {
        status = Some(
            drive(&admin, &ScriptedFanout::default(), &Clock::at(0), &id)
                .await
                .status,
        );
    })
    .await;
    assert_eq!(status, Some(FanoutStatus::Stale));
    assert!(lines
        .iter()
        .all(|line| !line.message.contains("may be out of step")));
    assert!(admin.session().take_change_notes(&group).is_empty());
}

// ── The mark, across a circle's commits ──────────────────────────────────────

/// Whether a commit removes nobody is one mark per circle, so it has to be
/// taken back before the next commit's record is written: a relay change is
/// marked and applied, and the removal staged after it in the same circle
/// must not inherit the mark. A day without a reachable relay never undoes
/// it.
#[tokio::test]
async fn a_removal_staged_after_a_marked_commit_of_its_circle_is_never_undone_at_the_bound() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let accepting = answering(&[(ONE, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let change = stage_relay_change(&admin, &group, &[ONE, TWO]).await;
    assert_eq!(
        drive(&admin, &accepting, &clock, &change).await.status,
        FanoutStatus::Confirmed,
        "premise: a change that removes nobody was marked, and applied",
    );

    let removal = the_one(
        admin
            .session()
            .remove_members_staging(&group, &[others[1].pubkey_hex()], STAGED_AT)
            .await
            .expect("the removal is staged")
            .fanouts,
    );
    let unreachable = answering(&[(ONE, &[Answer::Unreachable]), (TWO, &[Answer::Unreachable])]);
    for at in [0, DAY_MS, 2 * DAY_MS] {
        clock.set(at);
        assert_eq!(
            drive(&admin, &unreachable, &clock, &removal).await.status,
            FanoutStatus::Unresolved,
            "a removal read the mark of the change before it and was undone ({at} ms)",
        );
    }
    assert!(staged_ref(&admin, &group).await.is_some() && !can_send(&admin, &group).await);
    assert!(admin.session().peek_change_notes(&group).is_empty());
}

// ── The re-staging wait, across sessions ─────────────────────────────────────

/// The wait a refused eviction earned is the circle's, not the session's: a
/// new session inside it stages the engine's re-armed eviction and undoes it
/// unsent, as the session that earned the wait would have, and the doubling
/// carries over. A stored wait that lies further ahead of the clock than any
/// wait is over: a clock stepped back must not hold an eviction for the size
/// of the step.
#[tokio::test]
async fn the_wait_a_refused_eviction_earned_outlives_its_session() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Invalid])]);
    let clock = Clock::at(0);
    let first = stage_eviction_recorded(&admin, &others[1], &group, clock.now_ms()).await;
    assert_eq!(
        drive(&admin, &transport, &clock, &first).await.status,
        FanoutStatus::RolledBack
    );
    transport.calls();

    // A new session, a millisecond inside the wait.
    let admin = admin.reopen();
    clock.set(60 * SECOND_MS - 1);
    assert!(
        restage_eviction(&admin, &group, clock.now_ms())
            .await
            .is_none(),
        "a new session staged and recorded an eviction inside the wait its refusal earned",
    );
    assert_eq!(transport.call_count(), 0);
    assert!(staged_ref(&admin, &group).await.is_none());

    // The wait over: staged, sent once, refused again — and the next wait
    // is twice as long, in the session after that too.
    clock.set(60 * SECOND_MS);
    let again = restage_eviction(&admin, &group, clock.now_ms())
        .await
        .expect("the eviction is staged again once its wait is over");
    assert_eq!(
        drive(&admin, &transport, &clock, &again).await.status,
        FanoutStatus::RolledBack
    );
    assert_eq!(transport.calls().len(), 1);
    let admin = admin.reopen();
    clock.set(60 * SECOND_MS + 120 * SECOND_MS - 1);
    assert!(
        restage_eviction(&admin, &group, clock.now_ms())
            .await
            .is_none(),
        "the second wait was not twice the first after a restart",
    );
    assert_eq!(transport.call_count(), 0);

    // The clock stepped back two hours: the stored wait can no longer be
    // measured, and is over.
    let stepped = Clock(AtomicU64::new(STAGED_AT - 2 * HOUR_MS));
    assert!(
        restage_eviction(&admin, &group, stepped.now_ms())
            .await
            .is_some(),
        "a clock stepped back held an eviction behind a wait further ahead than any wait",
    );
}

// ── A rollback that could not retire its commit, with no record to say so ────

/// The plain rollback rewinds a commit and leaves its own stored row as sent;
/// Haven retires the row right after. When that write fails there is no
/// rolled-back fanout row to say so — the commit had no record — and a
/// convergence pass could select the row and merge a commit nobody was sent
/// (a relay change carries no path, so nothing stops it). So the session
/// remembers it, and no engine call is made until it is retired: each is
/// refused with a typed error, for every circle.
#[tokio::test]
async fn a_commit_a_plain_rollback_could_not_retire_holds_the_engine_until_it_is() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = admin.session().epoch(&group).await.expect("epoch");
    // Staged the way today's screens stage it: no record.
    let staged = admin
        .session()
        .update_relays(&group, vec![ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change is staged");
    let commit = commit_event_id(&staged);
    let pending = staged_ref(&admin, &group).await.expect("staged");
    let (db, key) = db_of(&admin);

    set_commit_retirement_fault_for_test(&db, &key, commit.as_bytes(), true).expect("arm");
    let lines = capture_haven_log(async {
        let _ = admin.session().publish_failed(pending).await;
    })
    .await;
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && commit_state(&admin, commit).await == Some(MessageState::Sent),
        "premise: rewound, and its row not retired",
    );
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "retiring the rewound commit's row failed",
        )),
        &[&hex::encode(group.as_slice()), &commit.to_hex(), CANARY],
    );

    // Nothing that could merge it reaches the engine, and the refusal is one
    // a caller can tell from every other error without reading it. A
    // location asked for meanwhile is deferred, as any send the engine was
    // not asked for is: nothing is wrong with the fix.
    assert!(matches!(
        admin.session().advance_convergence(&group).await,
        Err(NostrError::EngineHeld)
    ));
    assert!(matches!(
        admin
            .circle
            .seal_location_for_test(
                &group,
                &haven_core::location::LocationMessage::new(51.5, -0.12)
            )
            .await,
        Err(CircleError::EngineHeld)
    ));
    assert_eq!(commit_state(&admin, commit).await, Some(MessageState::Sent));

    // Once the row can be written, the first engine call retires it first.
    set_commit_retirement_fault_for_test(&db, &key, commit.as_bytes(), false).expect("disarm");
    serve_deadlines(&admin, &group).await;
    assert_eq!(
        commit_state(&admin, commit).await,
        Some(MessageState::Failed),
        "a rewound commit was not retired before the engine was asked to advance its circle",
    );
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before,
        "a commit no relay was ever sent was merged",
    );
    assert!(can_send(&admin, &group).await);
}

// ── A note is durable before its row goes ────────────────────────────────────

/// The stored rolled-back row is the only trace that a commit was undone
/// until its note is written, so no finisher deletes it first: not the pass
/// before the open, and not the engine gate. While the note cannot be
/// written the row stays and the engine is held; when it can, the note is
/// there before the row is gone.
#[tokio::test]
async fn a_rolled_back_row_is_kept_until_its_note_is_written_by_every_finisher() {
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let (admin, _others, group) = split(fx);
    let event = row(&admin, &id).await.event_id;
    let (db, key) = db_of(&admin);
    // Rolled back by the driver, its commit's row not retired: the row stays.
    set_commit_retirement_fault_for_test(&db, &key, event.as_bytes(), true).expect("arm");
    let refusing = answering(&[(ONE, &[Answer::Refused])]);
    assert_eq!(
        drive(&admin, &refusing, &Clock::at(0), &id).await.status,
        FanoutStatus::RolledBack
    );
    assert!(
        probe(&admin, &id).await.is_some(),
        "premise: the row is kept"
    );
    let CircleMember { circle, keys, dir } = admin;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    set_commit_retirement_fault_for_test(&db, &key, event.as_bytes(), false).expect("disarm");

    // The next process cannot write notes: the pass before its open leaves
    // the row, and so does the gate.
    let notes = std::sync::Arc::new(BalkyNotes::default());
    notes.refusing.store(true, Ordering::SeqCst);
    let session =
        SessionManager::new_unencrypted_with_notes(dir.path(), &keys, Some(notes.clone()))
            .expect("the store opens");
    let stored = || async {
        session
            .fanout_probe_for_test(&id)
            .await
            .expect("the store is read")
            .is_some()
    };
    assert!(
        stored().await,
        "the pass before the open deleted a rolled-back row whose note it could not write",
    );
    assert!(matches!(
        session.advance_convergence(&group).await,
        Err(NostrError::EngineHeld)
    ));
    assert!(
        stored().await && notes.peek(&group).is_empty(),
        "the engine gate deleted a rolled-back row whose note it could not write",
    );

    // The note can be written: it is, and only then does the row go.
    notes.refusing.store(false, Ordering::SeqCst);
    session
        .advance_convergence(&group)
        .await
        .expect("the engine is handed over once the rollback is finished");
    assert_eq!(notes.peek(&group), [ChangeNote::RemovalUndone]);
    assert!(!stored().await);
}

// ── A wake that ends while a relay is being waited for ───────────────────────

/// A clock a test sets, whose waits end when the test moves it past them.
struct WakeClock {
    now: AtomicU64,
    moved: tokio::sync::Notify,
}

impl WakeClock {
    fn at(offset_ms: u64) -> Self {
        Self {
            now: AtomicU64::new(STAGED_AT + offset_ms),
            moved: tokio::sync::Notify::new(),
        }
    }

    fn set(&self, offset_ms: u64) {
        self.now.store(STAGED_AT + offset_ms, Ordering::SeqCst);
        self.moved.notify_waiters();
    }
}

impl FanoutClock for WakeClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }

    fn until<'a>(
        &'a self,
        at_ms: u64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
        Box::pin(async move {
            loop {
                let moved = self.moved.notified();
                if self.now_ms() >= at_ms {
                    return;
                }
                moved.await;
            }
        })
    }
}

/// A wake's budget bounds the wait for a relay: a call still unanswered when
/// the wake ends is no longer waited for. Nothing is stored for it, so its
/// target stays as it was marked before the call — begun — which the next
/// drive reads as an attempt that never returned: possibly exposed. That is
/// what a wake the system cut off leaves, and it is never a rollback, whatever
/// the relay says afterwards.
#[tokio::test(flavor = "current_thread")]
async fn a_wake_that_ends_before_a_relay_answers_leaves_the_attempt_begun_and_undoes_nothing() {
    let fx = setup_circle(3, &[ONE]).await;
    let id = stage_removal(&fx).await;
    let (admin, _others, group) = split(fx);
    // Had it been waited for, this answer would have proved a refusal.
    let transport = answering(&[(ONE, &[Answer::Refused])]);
    transport.park();
    let clock = WakeClock::at(0);
    let ends = clock.now_ms() + ROW_BUDGET_MS;

    let mut due = None;
    let lines = capture_haven_log(async {
        let (ran, ()) = tokio::join!(
            drive_due(
                &admin.circle,
                &transport,
                &clock,
                Some(&group),
                Some(ends),
                &DriveMode::Full
            ),
            async {
                transport.parked().await;
                clock.set(ROW_BUDGET_MS);
            },
        );
        due = Some(ran);
    })
    .await;
    let due = due.expect("ran");
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "a wake ended before a relay answered; its attempt stays begun",
        )),
        &[&hex::encode(group.as_slice()), &admin.pubkey_hex(), CANARY],
    );
    assert!(due.error.is_none());
    assert_eq!(due.driven.len(), 1);
    assert_eq!(due.driven[0].1.status, FanoutStatus::Unresolved);
    assert_eq!(
        due.retry_after_ms,
        Some(0),
        "a row a wake's end cut short did not ask to be driven again",
    );
    assert_eq!(
        row(&admin, &id).await.statuses,
        [FanoutTargetStatus::Attempting],
        "an attempt the wake did not wait out was stored as answered",
    );
    assert!(staged_ref(&admin, &group).await.is_some());
    transport.unpark();

    // The next wake: the attempt never returned, so a relay may hold the
    // commit, and its refusal now undoes nothing.
    clock.set(ROW_BUDGET_MS + HOUR_MS);
    let outcome = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the drive runs"));
    assert_eq!(outcome.status, FanoutStatus::Unresolved);
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && admin.session().peek_change_notes(&group).is_empty(),
        "a commit whose attempt a wake cut off was rolled back",
    );
}
