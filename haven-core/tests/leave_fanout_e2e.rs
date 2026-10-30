//! Pressing Leave stops sharing at once, whatever else is pending; the leave
//! proposal is sent again byte for byte within an epoch and minted again by
//! the engine for a new one; and the leave ends at a bound measured from the
//! instant it was asked for.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted, so no
//! socket is opened and no clock but the driver's own is waited on.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::circle::CircleError;
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, SendIntent};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, LeaveStatus, LocationPublish, LocationSeal, ModeSource, Publishing, SendHeld,
    LEAVE_BOUND_MS, RETRY_MAX_MS, ROW_BUDGET_MS,
};
use helpers::drive::{
    epoch, leave_of, make_a_departure_due, ngid, sealed_by, staged_ref, through, within,
    ManualClock, Recorder,
};
use helpers::stranded::{split, staged};
use helpers::{assert_no_needles, capture_haven_log, setup_circle, CircleMember};
use nostr::JsonUtil as _;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

const ONE: &str = "wss://one.leave-canary7c2d.example.com";
const FULL: DriveMode = DriveMode::Full;
const FINISH_ONLY: DriveMode = DriveMode::FinishOnly;
const ROOM_MS: u64 = 2 * ROW_BUDGET_MS;

fn fix() -> LocationMessage {
    LocationMessage::new(48.85, 2.35)
}

/// What a seal through `driver` answered: the event, or why there was none.
async fn seal(
    driver: &Publishing<'_, ScriptedFanout>,
    member: &CircleMember,
    group: &GroupId,
) -> Result<nostr::Event, SendHeld> {
    match driver
        .seal_location(&member.circle, group, &fix())
        .await
        .expect("the seal runs")
        .seal
    {
        LocationSeal::Sealed { event, .. } => Ok(*event),
        LocationSeal::Deferred(held) => Err(held),
    }
}

/// The payloads of the calls made since the last read: the proposal's
/// bytes as each relay was handed them.
fn payloads(transport: &ScriptedFanout) -> Vec<Vec<u8>> {
    transport
        .calls()
        .into_iter()
        .map(|call| call.payload)
        .collect()
}

/// The circle store of `member`, opened beside its own handle.
fn circle_store(member: &CircleMember) -> rusqlite::Connection {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        member
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
}

/// Writes `member`'s leave intent the way a process that died right after
/// writing it leaves it: the circle store's row, and nothing in the engine.
fn intent_only(member: &CircleMember, group: &GroupId, at_secs: u64) {
    let rows = circle_store(member)
        .execute(
            "INSERT INTO user_settings (key, value) VALUES (?1, ?2)",
            [
                format!("leave_intent_v1:{}", hex::encode(group.as_slice())),
                at_secs.to_string(),
            ],
        )
        .expect("the intent is written");
    assert_eq!(rows, 1, "premise");
}

/// From the instant Leave is pressed nothing of the circle is sealed or
/// sent, on any entry and in any mode — the legacy send, the driver's seal
/// in the full mode and in a drive that only finishes, and after a restart
/// — and a location sealed just before is not sent after. A burst, a
/// session only started and a process with no live plane reach a circle
/// through these two entries alone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pending_leave_stops_location_publishing_on_every_plane_immediately() {
    let fx = setup_circle(3, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let before = seal(&driver, &member, &group)
        .await
        .unwrap_or_else(|_| panic!("premise: a location is sealed before the leave"));

    let left = driver
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave is accepted");
    assert!(left.status == LeaveStatus::Proposed, "premise: proposed");

    assert!(
        matches!(
            driver.publish_location(&member.circle, &before).await,
            LocationPublish::Ended | LocationPublish::Superseded
        ) && transport.location_call_count() == 0,
        "a location sealed before Leave was pressed was sent after it",
    );
    let narrow = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    assert!(
        matches!(seal(&driver, &member, &group).await, Err(SendHeld::Leaving))
            && matches!(seal(&narrow, &member, &group).await, Err(SendHeld::Leaving)),
        "a location was sealed for a circle this device is leaving",
    );
    let member = member.reopen();
    assert!(
        matches!(seal(&driver, &member, &group).await, Err(SendHeld::Leaving))
            && transport.location_call_count() == 0,
        "a restart ended the leave's hold on the circle's sharing",
    );
}

/// A leave proposal no relay acknowledged is sent again as the same bytes:
/// the engine's own stored proposal, never a fresh one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_leave_proposal_is_redriven_byte_identical_in_a_quiet_circle() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    let _ = driver
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave is accepted");
    let first = payloads(&transport);
    assert!(first.len() == 1, "premise: the proposal was sent once");

    let member = member.reopen();
    clock.set(LEAVE_BOUND_MS / 2);
    let again = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    let second = payloads(&transport);
    assert!(
        again.status == LeaveStatus::Proposed && second.len() == 1 && second[0] == first[0],
        "a leave proposal was sent again as anything but the bytes first sent",
    );
}

/// A leave pressed while a commit of this device's is pending stops sharing
/// at once, is not proposed while the circle cannot take one — the legacy
/// entry fails plainly — and is proposed once the commit is applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_pressed_while_a_commit_is_pending_stops_sharing_and_is_proposed_after_the_ack() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let effects = member
        .session()
        .send(SendIntent::SelfUpdate {
            group_id: group.clone(),
        })
        .await
        .expect("the member stages a commit of its own");
    let (_commit, pending) = staged(&effects);

    // The legacy leave fails plainly, and its intent stands.
    assert!(
        member.circle.propose_leave(&group).await.is_err()
            && payloads(&transport).is_empty()
            && member
                .circle
                .leave_intent_at(&group)
                .expect("read")
                .is_some(),
        "a legacy leave behind a pending commit did not fail plainly, or let its intent go",
    );
    let held = driver
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("a leave behind a pending commit is accepted");
    assert!(
        held.status == LeaveStatus::Pending
            && payloads(&transport).is_empty()
            && matches!(seal(&driver, &member, &group).await, Err(SendHeld::Leaving)),
        "a leave behind a pending commit was proposed, or let the circle share",
    );

    member
        .session()
        .confirm_published(pending)
        .await
        .expect("a relay took the commit");
    let proposed = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert!(
        proposed.status == LeaveStatus::Proposed && payloads(&transport).len() == 1,
        "the leave was not proposed once the pending commit was applied",
    );
}

/// A process that died after the engine recorded the leave and before its
/// proposal was handed anywhere still ends the leave: the engine refuses a
/// second proposal for that epoch, so nothing more is sent at it, and the
/// leave ends at its bound, measured from the intent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_between_the_leave_request_and_its_fanout_put_still_ends_the_leave() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _unsent = member
        .circle
        .propose_leave(&group)
        .await
        .expect("the engine records the leave")
        .expect("a first proposal for the epoch");
    let since_ms = u64::try_from(
        member
            .circle
            .leave_intent_at(&group)
            .expect("read")
            .expect("premise: the intent stands"),
    )
    .expect("after 1970")
        * 1_000;
    let member = member.reopen();
    let driver = through(&transport, &outbox, &clock, &FULL);

    clock.set(since_ms + LEAVE_BOUND_MS - 1_000 - ManualClock::ORIGIN);
    let early = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert!(
        early.status != LeaveStatus::Completed
            && matches!(seal(&driver, &member, &group).await, Err(SendHeld::Leaving)),
        "the leave ended before its bound, or let the circle share",
    );
    clock.set(since_ms + LEAVE_BOUND_MS - ManualClock::ORIGIN);
    let ended = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert!(
        ended.status == LeaveStatus::Completed
            && member
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_none(),
        "a leave whose proposal a kill kept from its relays never ended",
    );
}

/// A process that died right after writing the intent leaves no engine
/// trace of the leave; the next process proposes it, and shares nothing
/// before it does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_killed_between_the_mark_and_the_proposal_is_reproposed_on_reopen() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    intent_only(&member, &group, ManualClock::ORIGIN / 1_000);
    let member = member.reopen();
    let driver = through(&transport, &outbox, &clock, &FULL);
    assert!(
        matches!(seal(&driver, &member, &group).await, Err(SendHeld::Leaving)),
        "a circle whose leave intent stands shared before the leave was proposed",
    );
    let proposed = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert!(
        proposed.status == LeaveStatus::Proposed && payloads(&transport).len() == 1,
        "a leave whose process died before its proposal was not proposed by the next",
    );
}

/// The leave ends at its bound, a day from the instant Leave was first
/// pressed once a proposal has been minted: neither a later press nor a
/// later attempt moves it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pending_leave_ends_at_its_bound_anchored_on_the_intent_time() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = member.keys.public_key();

    let _ = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave is accepted");
    clock.set(LEAVE_BOUND_MS / 2);
    let _ = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("pressed again");
    clock.set(LEAVE_BOUND_MS - 1_000);
    let early = driver
        .resume_leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        early.status != LeaveStatus::Completed
            && member
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_some(),
        "the leave ended before a day had passed since it was first asked for",
    );
    clock.set(LEAVE_BOUND_MS);
    let ended = driver
        .resume_leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        ended.status == LeaveStatus::Completed
            && member
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_none(),
        "a leave nobody committed did not end a day after it was first asked for",
    );
}

/// A location sealed for a circle whose leave is then asked for, and not
/// yet sent, is deleted without a relay being contacted.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unattempted_location_for_a_leaving_circle_is_deleted_not_published() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let sealed = seal(&driver, &member, &group)
        .await
        .unwrap_or_else(|_| panic!("premise: sealed"));
    assert!(
        member
            .session()
            .location_records_for_test(&group)
            .await
            .expect("read")
            .len()
            == 1,
        "premise: recorded",
    );

    let _ = driver
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave is accepted");
    assert!(
        member
            .session()
            .location_records_for_test(&group)
            .await
            .expect("read")
            .is_empty()
            && matches!(
                driver.publish_location(&member.circle, &sealed).await,
                LocationPublish::Ended
            )
            && transport.location_call_count() == 0,
        "a location of a circle being left was published, or its record kept",
    );
}

/// When the circle moves to a new epoch, the engine mints the leave's next
/// proposal itself; it is recorded and sent, and the stale epoch's record
/// is never sent again, and is deleted once its attempt paces no relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fresh_leave_proposal_for_a_new_epoch_deletes_the_stale_epochs_fanout() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let other = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _ = driver
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave is accepted");
    let stale = member
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("read");
    let first = payloads(&transport);
    assert!(
        stale.len() == 1 && first.len() == 1,
        "premise: one proposal"
    );

    // The admin removes somebody else: a new epoch.
    let removal = admin
        .session()
        .remove_members(&group, &[other.pubkey_hex()])
        .await
        .expect("the admin removes the other member");
    let (commit, pending) = staged(&removal);
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("its relays took it");
    let before = epoch(&member, &group).await;
    clock.set(LEAVE_BOUND_MS / 4);
    let _ = driver
        .ingest_for_poll(&member.circle, &commit)
        .await
        .expect("the commit is ingested");
    assert!(
        epoch(&member, &group).await == before + 1,
        "premise: a new epoch"
    );
    let _ = driver.resume(&member.circle).await;
    let now = member
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("read");
    let sent = payloads(&transport);
    assert!(
        now.len() == 2 && now.contains(&stale[0]) && sent.len() == 1 && sent[0] != first[0],
        "the leave's proposal for the new epoch was not recorded and sent, or the stale \
         epoch's was sent again",
    );
    // The stale record makes no call; it is kept only while its unanswered
    // attempt is part of the schedule of a relay the new one still owes a
    // call, and is deleted once the relay has taken the new one.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(LEAVE_BOUND_MS / 2);
    let _ = driver.resume(&member.circle).await;
    let _ = driver.resume(&member.circle).await;
    let later = member
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("read");
    assert!(
        !later.contains(&stale[0]) && payloads(&transport).iter().all(|p| *p != first[0]),
        "the stale epoch's leave proposal was kept once it paced no relay, or was sent again",
    );
}

/// A leave the engine refuses for good — an admin who must step down first,
/// a circle it does not hold — ends its intent: the circle shares again,
/// and a later removal of this device reads as what it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_permanently_refused_leave_clears_the_intent_and_keeps_its_directory_semantics() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    assert!(
        matches!(
            admin.circle.propose_leave(&group).await,
            Err(CircleError::AdminSelfDemoteRequired)
        ),
        "premise: the sole admin must step down first",
    );
    assert!(
        admin
            .circle
            .leave_intent_at(&group)
            .expect("read")
            .is_none()
            && seal(&driver, &admin, &group).await.is_ok(),
        "a leave refused for good kept the circle from sharing",
    );

    let unknown = GroupId::new(vec![7_u8; 32]);
    assert!(
        matches!(
            admin.circle.propose_leave(&unknown).await,
            Err(CircleError::NotFound(_))
        ) && admin
            .circle
            .leave_intent_at(&unknown)
            .expect("read")
            .is_none(),
        "a leave of a circle the engine does not hold left its intent standing",
    );
}

/// A leave is the user's own act, made in front of the app: a drive that
/// makes no new commit still gives its proposal the first transmission.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_proposal_is_sent_by_a_drive_that_only_finishes() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let narrow = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let left = narrow
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave is accepted");
    assert!(
        left.status == LeaveStatus::Proposed && payloads(&transport).len() == 1,
        "a drive that only finishes did not send the leave's proposal",
    );
}

/// An admin's leave holds the circle's sharing from its first step, the
/// hand-over of the circle — not only once its own proposal is made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_admins_leave_holds_sharing_from_its_first_step() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pending = driver
        .leave(&admin.circle, &group, &admin.keys.public_key())
        .await
        .expect("the hand-over is staged");
    assert!(
        pending.status == LeaveStatus::Pending
            && matches!(seal(&driver, &admin, &group).await, Err(SendHeld::Leaving)),
        "an admin's leave let the circle share while its hand-over awaited its relays",
    );
}

/// A leave asked for while the legacy seal waits in its hand-back holds that
/// seal: the intent is read again with nothing awaited before it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_asked_for_while_the_legacy_seal_hands_back_holds_that_seal() {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let path = member
        .dir
        .path()
        .join(haven_core::circle::CIRCLES_DB_FILENAME);
    let key = format!("leave_intent_v1:{}", hex::encode(group.as_slice()));
    member.session().during_next_hand_back_for_test(move || {
        rusqlite::Connection::open(path)
            .expect("the circle store opens")
            .execute(
                "INSERT INTO user_settings (key, value) VALUES (?1, '1')",
                [key],
            )
            .expect("the intent is written");
    });
    assert!(
        matches!(
            member
                .session()
                .send_location(&group, fix().to_string().expect("a fix"))
                .await,
            Err(haven_core::nostr::NostrError::LeaveInProgress)
        ),
        "a seal that was waiting in its hand-back when Leave was pressed was made",
    );
}

/// A location sealed before a leave the legacy way — proposed, then left on
/// this device with no drive between — is never sent after: leaving the
/// circle ends its location records.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_sealed_before_a_leave_is_never_sent_once_the_circle_is_left() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let sealed = seal(&driver, &member, &group)
        .await
        .unwrap_or_else(|_| panic!("premise: sealed"));
    let _ = member
        .circle
        .propose_leave(&group)
        .await
        .expect("the leave is proposed");
    member
        .circle
        .complete_leave(&group, 1_700_000_000)
        .await
        .expect("the circle is left");
    assert!(
        member
            .session()
            .location_records_for_test(&group)
            .await
            .expect("read")
            .is_empty()
            && !matches!(
                driver.publish_location(&member.circle, &sealed).await,
                LocationPublish::Sent(_)
            )
            && transport.location_call_count() == 0,
        "a location of a circle this device has left was sent, or its record kept",
    );
}

/// Once the leave has completed its proposal is not sent again by any
/// drive, though its record's day has not run out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_proposal_is_not_sent_once_the_leave_has_completed() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = member.keys.public_key();
    let _ = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave is accepted");
    assert!(payloads(&transport).len() == 1, "premise: proposed once");
    member
        .circle
        .complete_leave(&group, 1_700_000_000)
        .await
        .expect("the circle is left");
    // Within the record's day, after the relay's longest wait: a record
    // still owed would be sent now.
    clock.set(RETRY_MAX_MS + 1_000);
    let _ = driver.resume(&member.circle).await;
    assert!(
        payloads(&transport).is_empty(),
        "a leave proposal was sent after the leave had completed",
    );
}

/// A leave whose intent lies further ahead of the clock than any wait —
/// the clock was stepped back — ends: its age can no longer be known. A
/// smaller step is an ordinary correction and ends nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_whose_intent_lies_ahead_of_a_stepped_back_clock_ends() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(LEAVE_BOUND_MS);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = member.keys.public_key();
    let _ = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave is accepted");
    clock.set(LEAVE_BOUND_MS - 60_000);
    let corrected = driver
        .resume_leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        corrected.status != LeaveStatus::Completed,
        "an ordinary correction of the clock ended the leave",
    );
    clock.set(LEAVE_BOUND_MS - RETRY_MAX_MS - 1_000);
    let ended = driver
        .resume_leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        ended.status == LeaveStatus::Completed,
        "a leave whose intent lies far ahead of a stepped-back clock did not end",
    );
}

/// A press that finds the intent standing and no proposal ever minted for
/// it renews the leave's instant (decision 218): the bound limits the wait
/// once a proposal can exist, and none could.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_press_that_finds_no_proposal_ever_minted_renews_the_leaves_instant() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = member.keys.public_key();
    let effects = member
        .session()
        .send(SendIntent::SelfUpdate {
            group_id: group.clone(),
        })
        .await
        .expect("the member stages a commit of its own");
    let (_commit, pending) = staged(&effects);
    let held = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("accepted");
    assert!(
        held.status == LeaveStatus::Pending,
        "premise: nothing proposed"
    );
    clock.set(LEAVE_BOUND_MS - 1_000);
    let _ = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("pressed again");
    member
        .session()
        .confirm_published(pending)
        .await
        .expect("a relay took the commit");
    clock.set(LEAVE_BOUND_MS + 1_000);
    let later = driver
        .resume_leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        later.status == LeaveStatus::Proposed && payloads(&transport).len() == 1,
        "a leave pressed again before any proposal could exist was ended by the first press's \
         bound instead of being proposed",
    );
}

/// A leave the engine queues behind the removal of a member who left is
/// taken back in the hold that queued it: nothing is left for a later drain
/// to mint outside a record, and the next attempt proposes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_the_engine_queued_is_taken_back_and_proposed_from_its_record() {
    let fx = setup_circle(4, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (_admin, others, group) = split(fx);
    let (device, witness) = (&others[1], &others[2]);
    make_a_departure_due(device, witness, &group, &leave).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = device.keys.public_key();
    let held = driver
        .leave(&device.circle, &group, &pubkey)
        .await
        .expect("accepted");
    assert!(
        held.status == LeaveStatus::Pending
            && device
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 0,
        "a leave the engine queued was left in its queue",
    );
    assert!(
        payloads(&transport).len() == 1,
        "premise: the removal the leave's send staged first was sent by the same call",
    );
    let proposed = driver
        .resume_leave(&device.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        proposed.status == LeaveStatus::Proposed && payloads(&transport).len() == 1,
        "the leave taken back was not proposed from a record by the next attempt",
    );
}

/// A leave refused for good whose intent cannot be cleared keeps the circle
/// held, and what is logged of it names no circle and no member.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_leave_whose_intent_cannot_be_cleared_holds_and_logs_nothing_identifying() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let needles = [
        hex::encode(group.as_slice()),
        hex::encode(ngid(&admin, &group).await),
        admin.pubkey_hex(),
    ];
    circle_store(&admin)
        .execute_batch(
            "CREATE TRIGGER keep_settings BEFORE DELETE ON user_settings \
             BEGIN SELECT RAISE(ABORT, 'kept'); END;",
        )
        .expect("the store refuses deletes");
    let mut refused = None;
    let lines = capture_haven_log(async {
        refused = Some(admin.circle.propose_leave(&group).await);
    })
    .await;
    assert!(
        matches!(refused, Some(Err(CircleError::AdminSelfDemoteRequired)))
            && matches!(seal(&driver, &admin, &group).await, Err(SendHeld::Leaving)),
        "premise: refused for good, and the intent that could not be cleared still holds",
    );
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        lines.iter().any(|line| line
            .message
            .contains("a refused leave's intent was not cleared")),
        "premise: the failure is logged",
    );
    assert_no_needles(
        &lines,
        &[&needles[0], &needles[1], &needles[2], "leave-canary7c2d"],
    );
}

/// A store that cannot say whether the circle's row stands holds a sealed
/// location's send, and one that cannot say whether a leave was asked for
/// holds the circle's seals; what is logged of either names nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unreadable_circle_store_holds_every_send_and_logs_nothing_identifying() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let needles = [
        hex::encode(group.as_slice()),
        hex::encode(ngid(&admin, &group).await),
        admin.pubkey_hex(),
    ];
    let sealed = seal(&driver, &admin, &group)
        .await
        .unwrap_or_else(|_| panic!("premise: sealed"));

    circle_store(&admin)
        .execute_batch("ALTER TABLE circles RENAME TO circles_unread;")
        .expect("the circles table is hidden");
    let mut sent = None;
    let lines = capture_haven_log(async {
        sent = Some(driver.publish_location(&admin.circle, &sealed).await);
    })
    .await;
    assert!(
        matches!(sent, Some(LocationPublish::Superseded)) && transport.location_call_count() == 0,
        "a location was sent though its circle's row could not be read",
    );
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        lines
            .iter()
            .any(|line| line.message.contains("a circle's row was not read")),
        "premise: the failure is logged",
    );
    assert_no_needles(
        &lines,
        &[&needles[0], &needles[1], &needles[2], "leave-canary7c2d"],
    );

    circle_store(&admin)
        .execute_batch(
            "ALTER TABLE circles_unread RENAME TO circles; \
             ALTER TABLE user_settings RENAME TO user_settings_unread;",
        )
        .expect("the settings table is hidden");
    let mut held = None;
    let lines = capture_haven_log(async {
        held = Some(Box::pin(seal(&driver, &admin, &group)).await);
    })
    .await;
    assert!(
        matches!(held, Some(Err(SendHeld::Leaving))),
        "a location was sealed though whether a leave was asked for could not be read",
    );
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        lines
            .iter()
            .any(|line| line.message.contains("a leave intent was not read")),
        "premise: the failure is logged",
    );
    assert_no_needles(
        &lines,
        &[&needles[0], &needles[1], &needles[2], "leave-canary7c2d"],
    );
}

/// An admin's leave runs its whole plan in one call when every step is
/// applied: the circle is handed over, the admin steps down, and the leave
/// is proposed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_admins_leave_hands_over_steps_down_and_proposes_in_one_call() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let before = epoch(&admin, &group).await;
    let left = driver
        .leave(&admin.circle, &group, &admin.keys.public_key())
        .await
        .expect("the leave runs");
    assert!(
        left.status == LeaveStatus::Proposed
            && epoch(&admin, &group).await == before + 2
            && payloads(&transport).len() == 3,
        "an admin's leave did not hand over, step down and propose in one call",
    );
}

/// A leave this device's copy has already seen made — a peer committed it —
/// ends on this device at the next attempt.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_a_peer_has_committed_ends_on_this_device() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let witness = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = member.keys.public_key();
    let _ = driver
        .leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave is proposed");
    let proposal = nostr::Event::from_json(
        transport
            .calls()
            .pop()
            .expect("premise: the proposal was sent")
            .payload,
    )
    .expect("the proposal's event");

    // The admin makes the eviction the leave asks for; the device applies it.
    make_a_departure_due(&admin, &witness, &group, &proposal).await;
    admin.session().mark_caught_up_for_test(&group);
    let commit_transport = ScriptedFanout::default();
    commit_transport.answer(ONE, [Answer::Accepted]);
    let _ = through(&commit_transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    let eviction = nostr::Event::from_json(
        commit_transport
            .calls()
            .pop()
            .expect("premise: the admin sent the eviction")
            .payload,
    )
    .expect("the eviction's event");
    let _ = member
        .session()
        .process_event_settled_for_test(&eviction)
        .await;
    assert!(
        member.session().removed_for_test(&group).await,
        "premise: this device's copy is marked removed",
    );
    let ended = driver
        .resume_leave(&member.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        ended.status == LeaveStatus::Completed
            && member
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_none(),
        "a leave a peer had committed did not end on this device",
    );
}

/// The last member of a circle leaves it on this device alone: there is
/// nobody to propose to.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_last_members_leave_abandons_the_circle_locally() {
    let fx = setup_circle(1, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let left = through(&transport, &outbox, &clock, &FULL)
        .leave(&admin.circle, &group, &admin.keys.public_key())
        .await
        .expect("the leave runs");
    assert!(
        left.status == LeaveStatus::Completed
            && admin
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_none()
            && payloads(&transport).is_empty(),
        "the last member's leave was not abandoned locally, or reached a relay",
    );
}

/// A leave proposal's record whose circle's row cannot be read is neither
/// sent nor ended by that pass: what cannot be read ends nothing, and what is
/// logged of it names nothing. Once the row reads again, it is sent when due.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_proposal_whose_circles_row_cannot_be_read_is_kept_untouched() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let needles = [
        hex::encode(group.as_slice()),
        hex::encode(ngid(&admin, &group).await),
        member.pubkey_hex(),
    ];
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _ = driver
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave is proposed");
    assert!(payloads(&transport).len() == 1, "premise: proposed once");
    let record = member
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("read");

    circle_store(&member)
        .execute_batch("ALTER TABLE circles RENAME TO circles_unread;")
        .expect("the circles table is hidden");
    clock.set(RETRY_MAX_MS + 1_000);
    let lines = capture_haven_log(Box::pin(async {
        let _ = driver.resume(&member.circle).await;
    }))
    .await;
    assert!(
        payloads(&transport).is_empty()
            && member
                .session()
                .fanout_ids_for_test(&group)
                .await
                .expect("read")
                == record,
        "a leave proposal whose circle's row could not be read was sent, or ended",
    );
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        lines
            .iter()
            .any(|line| line.message.contains("a circle's row was not read")),
        "premise: the failure is logged",
    );
    assert_no_needles(
        &lines,
        &[&needles[0], &needles[1], &needles[2], "leave-canary7c2d"],
    );

    circle_store(&member)
        .execute_batch("ALTER TABLE circles_unread RENAME TO circles;")
        .expect("the circles table reads again");
    let _ = driver.resume(&member.circle).await;
    assert!(
        payloads(&transport).len() == 1,
        "a leave proposal kept while its circle's row could not be read was not sent once it \
         could",
    );
}

/// The legacy leave, queued by the engine behind the removal of a member who
/// left, is answered as standing — not as a failure — and left queued for
/// the engine's own drain to propose (decision 222).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_legacy_leave_the_engine_queued_stands_and_stays_queued() {
    let fx = setup_circle(4, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (_admin, others, group) = split(fx);
    let (device, witness) = (&others[1], &others[2]);
    make_a_departure_due(device, witness, &group, &leave).await;
    let answered = device.circle.propose_leave(&group).await;
    assert!(
        matches!(answered, Ok(None))
            && device
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 1,
        "a legacy leave the engine queued was answered as a failure, or taken out of the queue",
    );
}

/// A leave whose proposal the engine holds and no record of which stands —
/// proposed the legacy way, handed to a caller and never recorded — is not
/// answered as proposed by the driver: nothing says it was sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_proposed_with_no_record_is_not_answered_as_proposed() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let _ = member
        .circle
        .propose_leave(&group)
        .await
        .expect("the legacy leave is proposed")
        .expect("a first leave in this epoch proposes");
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    // The intent's own instant, so the leave is inside its day.
    let since_secs = member
        .circle
        .leave_intent_at(&group)
        .expect("read")
        .expect("the legacy leave wrote its intent");
    let clock = ManualClock::at(
        (u64::try_from(since_secs).expect("a past instant") * 1_000)
            .checked_sub(ManualClock::ORIGIN)
            .expect("the intent is after the clock's origin"),
    );
    let driver = through(&transport, &outbox, &clock, &FULL);
    let carried = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert_eq!(
        carried.status,
        LeaveStatus::Pending,
        "a proposal no record stands for was answered as proposed",
    );
}

/// The foreground of a call that ends while the call waits in its hand-back:
/// full, and standing, until the hand-back it is armed for runs; finish-only,
/// and ended, from then on.
struct EndsInTheHandBack(Arc<AtomicBool>);

impl ModeSource for EndsInTheHandBack {
    fn mode(&self) -> DriveMode {
        if self.0.load(Ordering::SeqCst) {
            FINISH_ONLY
        } else {
            FULL
        }
    }

    fn stands(&self) -> bool {
        !self.0.load(Ordering::SeqCst)
    }
}

/// A foreground that ends in `member`'s next hand-back of stranded input.
fn ends_in_the_next_hand_back(member: &CircleMember) -> EndsInTheHandBack {
    let ended = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&ended);
    member
        .session()
        .during_next_hand_back_for_test(move || flag.store(true, Ordering::SeqCst));
    EndsInTheHandBack(ended)
}

/// A circle of four whose member 1 has left and whose eviction of that member
/// is due on `others[1]`, with `others[2]` its witness.
async fn a_departure_due() -> (Vec<CircleMember>, GroupId) {
    let fx = setup_circle(4, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (_admin, others, group) = split(fx);
    make_a_departure_due(&others[1], &others[2], &group, &leave).await;
    (others, group)
}

/// A send asked for in the foreground, with the eviction of a member who left
/// due, is held when that foreground ends while the send waits in its
/// hand-back: the decision is asked again after it, and a hold that makes no
/// commit seals nothing the member who left can read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_whose_foreground_ends_in_its_hand_back_is_held_for_a_due_departure() {
    let (others, group) = a_departure_due().await;
    let device = &others[1];
    assert_eq!(
        device
            .session()
            .departure_holds_a_send_for_test(&group, 0, &FULL)
            .await
            .expect("asked"),
        None,
        "premise: in a foreground that stands, nothing holds the send",
    );
    let ending = ends_in_the_next_hand_back(device);
    assert_eq!(
        device
            .session()
            .departure_holds_a_send_for_test(&group, 0, &ending)
            .await
            .expect("asked"),
        Some(true),
        "a send whose foreground ended in its hand-back was let through to a preflight that \
         stages the due eviction",
    );
}

/// A leave asked for in the foreground, with the eviction of a member who
/// left due, records no eviction when that foreground ends while the leave
/// waits in its hand-back: the eviction its preflight stages is undone in the
/// hold, as in any hold that makes no commit — where a leave whose
/// foreground stands records it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_whose_foreground_ends_in_its_hand_back_records_no_eviction() {
    let (others, group) = a_departure_due().await;
    let device = &others[1];
    let standing = device
        .session()
        .leave_group_staging_for_test(&group, 0, &FULL)
        .await
        .expect("the leave is asked")
        .expect("no proposal of this epoch exists yet");
    assert!(
        !standing.fanouts.is_empty() && staged_ref(device, &group).await.is_some(),
        "premise: a leave whose foreground stands records that eviction",
    );

    let (others, group) = a_departure_due().await;
    let device = &others[1];
    let ending = ends_in_the_next_hand_back(device);
    let ended = device
        .session()
        .leave_group_staging_for_test(&group, 0, &ending)
        .await
        .expect("the leave is asked")
        .expect("no proposal of this epoch exists yet");
    assert!(
        ended.fanouts.is_empty() && staged_ref(device, &group).await.is_none(),
        "a leave whose foreground ended in its hand-back recorded the eviction its preflight \
         staged",
    );
}

/// An ingest records no commit when its foreground ends while it waits in
/// its hand-back — nor, on MDK v0.10.4, in a foreground that stands: the
/// engine's ingest only schedules a departure's eviction
/// (`cgka-engine/src/message_processor/ingest.rs` 1940-1950) and stages it
/// in an advance or a send's preflight alone (`mod.rs` 1151, 1231). An MDK
/// that stages at ingest fails the second half, and the re-read of the mode
/// after the hand-back is then what keeps the first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ingest_whose_foreground_ends_in_its_hand_back_records_no_commit() {
    let (others, group) = a_departure_due().await;
    let (device, witness) = (&others[1], &others[2]);
    let ending = ends_in_the_next_hand_back(device);
    let (_, ended) = device
        .session()
        .process_event_staging_for_test(&sealed_by(witness, &group, 30.25).await, 0, &ending)
        .await
        .expect("the ingest runs");
    assert!(
        ended.is_empty() && staged_ref(device, &group).await.is_none(),
        "an ingest whose foreground ended in its hand-back recorded a commit",
    );
    let (_, standing) = device
        .session()
        .process_event_staging_for_test(&sealed_by(witness, &group, 30.5).await, 0, &FULL)
        .await
        .expect("the ingest runs");
    assert!(
        standing.is_empty()
            && staged_ref(device, &group).await.is_none()
            && device
                .session()
                .eviction_due_after_for_test(&group)
                .await
                .is_some(),
        "MDK's ingest now stages a due eviction: an ingest's mode decides a commit",
    );
}

/// The eviction of a member who left, due in a circle whose routing id is
/// another circle's on this device too, is made by no advance of this
/// device's — the driver's, a receive plane's or the legacy repair's — and
/// wakes no receive pass: in the circle MDK stopped routing to it would be a
/// fork at an epoch the circle may have left. It stays due. The leave is the
/// one exception: the engine's own leave stages the due eviction before it
/// proposes, so that one commit goes with the leave, to the circle's own
/// relays; the leave is proposed, and ends at its bound.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_due_eviction_in_a_collided_circle_is_not_made_and_the_leave_still_ends() {
    let (others, group) = a_departure_due().await;
    let (gone, device, witness) = (others[0].pubkey_hex(), &others[1], &others[2]);
    device
        .session()
        .note_routing_collision_for_test(&group)
        .expect("the hold is noted");
    device.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _ = driver.resume(&device.circle).await;
    let fix = sealed_by(witness, &group, 21.0).await;
    let _ = driver
        .ingest_for_poll(&device.circle, &fix)
        .await
        .expect("a fix is received");
    let received = device
        .session()
        .advance_for_receive(&group)
        .await
        .expect("a receive plane advances");
    let legacy = device
        .session()
        .advance_convergence(&group)
        .await
        .expect("the legacy repair advances");
    assert!(
        transport.calls().is_empty()
            && received.publish.is_empty()
            && legacy.publish.is_empty()
            && device
                .session()
                .receive_retick_after(&group)
                .await
                .is_none()
            && staged_ref(device, &group).await.is_none()
            && helpers::drive::roster(device, &group).await.contains(&gone)
            && device
                .session()
                .eviction_due_after_for_test(&group)
                .await
                .is_some(),
        "an eviction was made in a circle whose routing id is shared, or stopped being due",
    );

    let pubkey = device.keys.public_key();
    let first = driver
        .leave(&device.circle, &group, &pubkey)
        .await
        .expect("the leave is accepted");
    let sent = transport.calls();
    assert!(
        first.status == LeaveStatus::Pending
            && sent.len() == 1
            && sent[0].target == ONE
            && !helpers::drive::roster(device, &group).await.contains(&gone),
        "the eviction the leave's own call stages did not go with it, to the circle's relays",
    );
    let proposed = driver
        .resume_leave(&device.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    let sent = transport.calls();
    assert!(
        proposed.status == LeaveStatus::Proposed && sent.len() == 1 && sent[0].target == ONE,
        "the leave of a held circle was not proposed at its own relays",
    );
    clock.set(LEAVE_BOUND_MS + 1_000);
    let ended = driver
        .resume_leave(&device.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        ended.status == LeaveStatus::Completed
            && device
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_none(),
        "the leave of a held circle did not end at its bound",
    );
}

/// The relay each call went to and the routing id its event is addressed to
/// (its `h` tag).
fn addressed(calls: Vec<haven_core::relay::fanout::scripted::Call>) -> Vec<(String, String)> {
    calls
        .into_iter()
        .map(|call| {
            let event = nostr::Event::from_json(&call.payload).expect("a sent event");
            let h = event
                .tags
                .iter()
                .find(|tag| tag.kind() == nostr::TagKind::h())
                .and_then(|tag| tag.content())
                .expect("an h tag")
                .to_string();
            (call.target, h)
        })
        .collect()
}

/// A leave proposal of another circle left in the engine's one-shot buffer
/// — re-minted for the epoch a commit moved that circle to, and collected by
/// whichever engine call comes next — is recorded for the circle MDK's own
/// record of it names, and sent to that circle's relays, when that next call
/// is a leave of a circle on other relays; never to the leaving circle's
/// relays, which it would tell of a circle they do not carry.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn another_circles_proposal_a_leave_hands_back_goes_to_that_circles_relays() {
    use haven_core::nostr::mls::types::PublishWork;
    const A: &str = "wss://a.leave-canary9e4f.example.com";
    const B: &str = "wss://b.leave-canary9e4f.example.com";
    let (device, admin_a, peer, admin_b) = (
        CircleMember::new(),
        CircleMember::new(),
        CircleMember::new(),
        CircleMember::new(),
    );
    let group_a = helpers::found_circle(&admin_a, &[&device, &peer], &[A]).await;
    let group_b = helpers::found_circle(&admin_b, &[&device], &[B]).await;
    let (id_a, id_b) = (
        hex::encode(ngid(&device, &group_a).await),
        hex::encode(ngid(&device, &group_b).await),
    );
    let transport = ScriptedFanout::default();
    transport.answer(A, [Answer::Accepted; 8]);
    transport.answer(B, [Answer::Accepted; 8]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let pubkey = device.keys.public_key();
    let _ = driver
        .leave(&device.circle, &group_a, &pubkey)
        .await
        .expect("the leave of A is proposed");
    let commit = helpers::removals::confirmed(
        &admin_a,
        &admin_a
            .session()
            .remove_members(&group_a, &[peer.pubkey_hex()])
            .await
            .expect("A's admin removes the peer"),
    )
    .await;
    let _ = device
        .session()
        .process_event(&commit)
        .await
        .expect("the commit is taken in");
    let mut reminted = device
        .session()
        .settle_receive_for_test(&group_a)
        .await
        .expect("the commit is applied");
    // A receive advance takes inputs only; the full one re-mints the leave.
    reminted.publish.extend(
        device
            .session()
            .advance_convergence(&group_a)
            .await
            .expect("the full advance")
            .publish,
    );
    assert!(
        reminted
            .publish
            .iter()
            .any(|work| matches!(work, PublishWork::Proposal { .. })),
        "premise: the engine re-minted A's leave for the epoch the commit reached",
    );
    device.session().strand_effects_for_test(reminted);
    let _ = transport.calls();

    let _ = driver
        .leave(&device.circle, &group_b, &pubkey)
        .await
        .expect("the leave of B is answered");
    let sent = addressed(transport.calls());
    assert!(
        sent.iter()
            .all(|(to, h)| (*h == id_a && to == A) || (*h == id_b && to == B)),
        "a circle's leave proposal reached another circle's relays ({} of {} calls to A's)",
        sent.iter().filter(|(to, _)| to == A).count(),
        sent.len(),
    );
    assert!(
        sent.iter().any(|(to, h)| to == A && *h == id_a)
            && sent.iter().any(|(to, h)| to == B && *h == id_b),
        "A's re-minted proposal or B's own was not sent to its circle's relays",
    );
}
