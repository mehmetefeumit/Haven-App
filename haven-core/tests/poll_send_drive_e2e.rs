//! The poll plane's and the location send's entries on the durable fanout
//! driver (Security Rule 13), in the full mode.
//!
//! One Rust call ingests a polled `kind:445` in staging mode and drives what
//! it staged; one seals a location after driving its circle's pending commit,
//! with whatever the send's own preflight stages recorded in that hold. No
//! commit is handed to a ladder and none is written into the legacy
//! obligation table. Nothing in the app calls either yet.

mod helpers;

use std::sync::Arc;

use haven_core::circle::CircleError;
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
use haven_core::nostr::mls::types::{FanoutMls, FanoutTargetStatus, GroupId};
use haven_core::nostr::mls::{ChangeNote, StorageConfig};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::fanout::{
    DriveMode, FanoutClock, FanoutSend, LocationSeal, SendHeld, ROW_BUDGET_MS,
};
use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveDriver};
use haven_core::relay::ReceiveOnlyOutcome;
use helpers::drive::{
    arrived_at, epoch, follows_the_eviction, has_fix, leave_of, make_a_departure_due,
    newest_commit_row, reads, records_of, roster, sealed_by, staged_ref, stored_fix, through,
    wait_out_the_engine, ManualClock, Recorder, MINUTE_MS, SECOND_MS,
};
use helpers::{setup_circle, CircleFixture, CircleMember};
use nostr::{Event, JsonUtil as _};

const ONE: &str = "wss://one.poll-canary2c6a.example.com";
const TWO: &str = "wss://two.poll-canary2c6a.example.com";

const FULL: DriveMode = DriveMode::Full;

fn split(fx: CircleFixture) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let mut members = fx.members;
    let admin = members.remove(0);
    (admin, members, fx.group)
}

fn fix() -> LocationMessage {
    LocationMessage::new(51.5, -0.12)
}

/// A three-member circle whose admin has handed over to its last member,
/// recorded for `relays`, the first call to each answered as scripted: the
/// commit is awaiting them. Returns the epoch the commit was staged at.
async fn a_hand_over_awaiting(
    relays: &[(&str, Answer)],
) -> (
    CircleMember,
    Vec<CircleMember>,
    GroupId,
    ScriptedFanout,
    u64,
) {
    let urls: Vec<&str> = relays.iter().map(|(url, _)| *url).collect();
    let fx = setup_circle(3, &urls).await;
    let (admin, others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let transport = ScriptedFanout::default();
    for (relay, first) in relays {
        transport.answer(relay, [*first]);
    }
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .admin_handoff(&admin.circle, &group, &others[1].keys.public_key())
        .await
        .expect("the hand-over is accepted");
    transport.calls();
    (admin, others, group, transport, source)
}

/// Lets `member` apply `commit`, served as a receive plane serves it.
async fn applies(member: &CircleMember, commit: &Event) {
    member
        .session()
        .process_event_settled_for_test(commit)
        .await
        .expect("the commit is ingested");
}

// ── The poll entry ───────────────────────────────────────────────────────────

/// The removal owed after a member's departure is made by a poll in a
/// claimed foreground (the full mode; the Android service polls finish-only
/// and leaves it to a foreground, which
/// `the_fgs_cycles_finish_only_calls_leave_an_owed_removal_to_a_foreground_and_hold_sends`
/// owns), through the driver alone: the leave and the fixes
/// that follow go through the driver's poll entry, the eviction is recorded
/// in the hold that stages it, sent to the circle's relay and applied on its
/// acknowledgement. And the removal removes: the member who left read the
/// circle before, and does not read what is sealed after.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_owed_after_a_departure_is_made_by_a_foreground_poll() {
    let fx = setup_circle(3, &[ONE]).await;
    let before = sealed_by(&fx.members[2], &fx.group, 5.0).await;
    assert!(
        reads(&fx.members[1], &before).await,
        "control: the member reads the circle before it leaves",
    );
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    let (leaver, witness) = (&others[0], &others[1]);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let cycle = through(&transport, &outbox, &clock, &FULL);

    let _ = cycle
        .ingest_for_poll(&admin.circle, &leave)
        .await
        .expect("the leave is ingested");
    for tick in 0..8_u32 {
        if !roster(&admin, &group).await.contains(&leaver.pubkey_hex()) {
            break;
        }
        wait_out_the_engine(&admin, &group).await;
        let polled = sealed_by(witness, &group, f64::from(tick).mul_add(0.5, 30.0)).await;
        let _ = cycle
            .ingest_for_poll(&admin.circle, &polled)
            .await
            .expect("a polled fix is ingested");
    }
    let calls = transport.calls();
    assert_eq!(
        calls.len(),
        1,
        "the eviction was not sent once to its relay"
    );
    let eviction = Event::from_json(&calls[0].payload).expect("a signed event");
    assert_eq!(eviction.kind.as_u16(), 445);
    assert!(
        !roster(&admin, &group).await.contains(&leaver.pubkey_hex())
            && staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty(),
        "the eviction was not applied on the relay's word",
    );
    assert!(
        outbox.handed().is_empty(),
        "the eviction was handed to the publisher of what has no record",
    );

    // The same cycle's send, after the eviction: sealed for those who remain.
    follows_the_eviction(witness, &leave, &eviction).await;
    let sent = cycle
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    let LocationSeal::Sealed { event, relays, .. } = sent.seal else {
        panic!("the send after the eviction is not sealed");
    };
    assert_eq!(relays, [ONE.to_string()]);
    assert!(
        reads(witness, &event).await && !reads(leaver, &event).await,
        "the remaining member does not read the location, or the departed one does",
    );
}

/// A peer's fix that waited behind this device's pending commit is replayed
/// by the confirm the poll entry's own drive makes, and reaches the same
/// three places an ingested fix does: the last-known store, the circle's "a
/// peer's fix arrived" stamp, and the outcome the call returns.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fix_replayed_inside_a_poll_plane_confirm_reaches_store_liveness_and_the_returned_outcome(
) {
    let (admin, others, group, transport, _) = a_hand_over_awaiting(&[(ONE, Answer::Silent)]).await;
    let witness = &others[0];
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let poll = through(&transport, &outbox, &clock, &FULL);
    let arrived_before = arrived_at(&admin, &group).await;

    let waiting = sealed_by(witness, &group, 48.25).await;
    let held = poll
        .ingest_for_poll(&admin.circle, &waiting)
        .await
        .expect("the fix is ingested");
    assert!(
        held.replayed.is_empty() && !stored_fix(&admin, &group, witness, 48.25).await,
        "premise: the engine holds a fix that arrives behind the pending commit",
    );
    assert_eq!(
        held.verdict,
        ReceiveOnlyOutcome::Deferred,
        "an event the engine only buffered behind a pending commit did not hold the \
         poll's cursor (Security Rule 12)",
    );
    assert!(transport.calls().is_empty(), "the relay was not due");

    // The relay answers when it is next due; the next polled event's call
    // drives the pending commit first. That event is ANOTHER member's: the
    // store keeps one fix a member, the freshest by the second, so a later
    // fix of the witness's own would replace the replayed one whenever the
    // two were sealed either side of a second's boundary.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(31 * SECOND_MS);
    let next = sealed_by(&others[1], &group, 48.5).await;
    let polled = poll
        .ingest_for_poll(&admin.circle, &next)
        .await
        .expect("the next fix is ingested");
    assert_eq!(transport.calls().len(), 1);
    assert!(
        has_fix(&polled.replayed, witness, 48.25),
        "the replayed fix is not in the outcome the call returned",
    );
    assert!(
        stored_fix(&admin, &group, witness, 48.25).await,
        "the replayed fix is not in the last-known store",
    );
    assert!(
        arrived_at(&admin, &group).await > arrived_before,
        "the replayed fix did not stamp its circle as one a fix arrived in",
    );
    assert!(staged_ref(&admin, &group).await.is_none() && !polled.errored);
    assert_eq!(
        polled.verdict,
        ReceiveOnlyOutcome::Applied,
        "an event the engine applied held the poll's cursor",
    );
}

// ── The send entry ───────────────────────────────────────────────────────────

/// A commit awaiting its relay holds its circle's sends; the send entry
/// drives it first, so the acknowledgement that is due applies it and the
/// very send that asked is sealed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_acked_commit_unblocks_the_same_location_send() {
    let (admin, others, group, transport, source) =
        a_hand_over_awaiting(&[(ONE, Answer::Silent)]).await;
    let frozen = records_of(&admin, &group).await.remove(0);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let send = through(&transport, &outbox, &clock, &FULL);

    // Not due: no relay is called, and the answer says what the circle
    // waits for — twice over, with the record left exactly as it was.
    for _ in 0..2 {
        let held = send
            .seal_location(&admin.circle, &group, &fix())
            .await
            .expect("the send runs");
        assert!(
            matches!(held.seal, LocationSeal::Deferred(SendHeld::AwaitingRelays)),
            "a send behind a commit awaiting its relay was not answered as awaiting relays",
        );
        assert!(!held.errored && held.retry_after_ms.is_some_and(|wait| wait > 0));
    }
    let untouched = records_of(&admin, &group).await.remove(0);
    assert!(
        transport.calls().is_empty()
            && untouched.attempts == frozen.attempts
            && untouched.statuses == frozen.statuses
            && outbox.handed().is_empty(),
        "a send called a relay that was not due, or changed the record",
    );

    transport.answer(ONE, [Answer::Accepted]);
    clock.set(31 * SECOND_MS);
    let outcome = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    let calls = transport.calls();
    assert!(
        calls.len() == 1 && calls[0].payload == frozen.payload,
        "the pending commit's own bytes were not sent once",
    );
    let LocationSeal::Sealed { event, .. } = outcome.seal else {
        panic!("the send that drove its commit to an acknowledgement was not sealed");
    };
    assert_eq!(epoch(&admin, &group).await, source + 1);
    applies(
        &others[0],
        &Event::from_json(&frozen.payload).expect("the commit"),
    )
    .await;
    assert!(
        reads(&others[0], &event).await,
        "the location was not sealed at the epoch the acknowledged commit leads to",
    );
}

/// What the send entry's own drive may add to a location send: nothing for a
/// circle with no pending commit — no relay is called for it, whatever its
/// applied commits still owe — and a typed deferral, with no call at all,
/// while a pending commit's relay is not due.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_with_no_pending_commit_calls_no_relay_whatever_its_circle_still_owes() {
    // Applied on ONE's word; TWO never answered and is owed its retries.
    let (admin, _others, group, transport, source) =
        a_hand_over_awaiting(&[(ONE, Answer::Accepted), (TWO, Answer::Silent)]).await;
    assert_eq!(epoch(&admin, &group).await, source + 1, "premise: applied");
    let owing = records_of(&admin, &group).await;
    assert_eq!(owing.len(), 1, "premise: the record still owes a relay");
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    let send = through(&transport, &outbox, &clock, &FULL);

    let outcome = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(
        matches!(outcome.seal, LocationSeal::Sealed { .. }),
        "a relay an applied commit still owes held a location back",
    );
    assert!(
        transport.calls().is_empty() && outbox.handed().is_empty(),
        "a location send called a relay for a commit that is not pending",
    );
    assert_eq!(
        records_of(&admin, &group).await[0].attempts,
        owing[0].attempts
    );

    // That relay is the resume's.
    let _ = send.resume(&admin.circle).await;
    let calls = transport.calls();
    assert!(calls.len() == 1 && calls[0].target == TWO);
}

/// Two callers of one process ask for the same circle at once — the UI's
/// isolate and the foreground service's share one session. While the first
/// one's call to the relay is out, the second finds the record being driven:
/// it sends nothing, is answered as awaiting relays, and the relay is never
/// sent the event twice at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_callers_of_one_circle_at_once_send_its_commit_once() {
    let (admin, _others, group, transport, source) =
        a_hand_over_awaiting(&[(ONE, Answer::Silent)]).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    transport.park();

    let first = through(&transport, &outbox, &clock, &FULL);
    let second = through(&transport, &outbox, &clock, &FULL);
    let location = fix();
    let out = first.seal_location(&admin.circle, &group, &location);
    tokio::pin!(out);
    tokio::select! {
        biased;
        _ = &mut out => panic!("the first call finished while its relay call was parked"),
        () = transport.parked() => {}
    }
    let beside = second
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the second call runs");
    assert!(
        matches!(
            beside.seal,
            LocationSeal::Deferred(SendHeld::AwaitingRelays)
        ),
        "a second caller beside a drive under way was not answered as awaiting relays",
    );
    assert_eq!(
        (transport.call_count(), transport.most_at_once()),
        (1, 1),
        "the commit was sent twice at once",
    );

    transport.unpark();
    let sent = out.await.expect("the first call runs");
    assert!(matches!(sent.seal, LocationSeal::Sealed { .. }));
    assert_eq!(epoch(&admin, &group).await, source + 1);
    assert_eq!(transport.calls().len(), 1);
}

// ── The preflight's eviction, and the wait a refusal earns ───────────────────

/// A three-member circle whose admin holds a member's leave with the
/// eviction due and nothing made of it yet.
async fn a_departure_due() -> (CircleMember, Vec<CircleMember>, GroupId) {
    let fx = setup_circle(3, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    make_a_departure_due(&admin, &others[1], &group, &leave).await;
    (admin, others, group)
}

/// An eviction left due is staged by a full drive only once its circle is
/// caught up in this session: made from an epoch the circle may have left, a
/// removal another member already made would fork the circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_left_due_is_staged_only_once_its_circle_is_caught_up() {
    let (admin, others, group) = a_departure_due().await;
    let leaver = &others[0];
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let drive = through(&transport, &outbox, &clock, &FULL);

    let _ = drive.resume(&admin.circle).await;
    assert!(
        transport.calls().is_empty()
            && staged_ref(&admin, &group).await.is_none()
            && roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "an eviction left due was staged before its circle was caught up",
    );
    admin.session().mark_caught_up_for_test(&group);
    let _ = drive.resume(&admin.circle).await;
    assert!(
        transport.calls().len() == 1
            && !roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "an eviction left due was not made once its circle was caught up",
    );
}

/// The eviction the send's own preflight stages is recorded in that hold and
/// driven by the call — never handed back for a ladder. When every relay
/// refuses it, it is undone and the circle waits; inside that wait neither
/// send path stages it again, not even to undo it, and nothing is sealed at
/// the epoch the member who left can read. When the wait is over the next
/// send records it again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_eviction_is_staged_by_no_send_inside_its_wait_and_again_after_it() {
    let (admin, others, group) = a_departure_due().await;
    let leaver = &others[0];
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let send = through(&transport, &outbox, &clock, &FULL);

    let refused = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(transport.calls().len(), 1, "the eviction was not sent");
    assert!(
        matches!(refused.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
        "a send whose eviction every relay refused was not answered as held by the departure",
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        vec![ChangeNote::RemovalUndone]
    );
    assert!(staged_ref(&admin, &group).await.is_none());

    // Inside the wait: both send paths, three ticks.
    admin
        .session()
        .set_legacy_clock_for_test(ManualClock::ORIGIN + 30 * SECOND_MS);
    let refused_row = newest_commit_row(&admin, &group).await;
    assert!(
        refused_row.is_some(),
        "premise: the refused eviction left its row"
    );
    for tick in [10, 30, 59] {
        wait_out_the_engine(&admin, &group).await;
        clock.set(tick * SECOND_MS);
        let held = send
            .seal_location(&admin.circle, &group, &fix())
            .await
            .expect("the send runs");
        assert!(matches!(
            held.seal,
            LocationSeal::Deferred(SendHeld::DepartureDue)
        ));
        let finishing = admin.circle.seal_location_for_test(&group, &fix()).await;
        assert!(
            matches!(finishing, Err(CircleError::EngineHeld)),
            "a send that makes no commit inside the wait was sealed",
        );
        assert!(staged_ref(&admin, &group).await.is_none());
    }
    assert_eq!(
        newest_commit_row(&admin, &group).await,
        refused_row,
        "a send inside the wait staged the eviction and undid it: one more dead commit row",
    );
    assert!(
        transport.calls().is_empty()
            && records_of(&admin, &group).await.is_empty()
            && outbox.handed().is_empty(),
        "a send inside the wait recorded, owed or sent the eviction",
    );
    assert!(roster(&admin, &group).await.contains(&leaver.pubkey_hex()));

    // The wait is over: the next send's preflight stages it under a record.
    clock.set(61 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    wait_out_the_engine(&admin, &group).await;
    let made = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(matches!(
        made.seal,
        LocationSeal::Deferred(SendHeld::Nothing)
    ));
    assert_eq!(transport.calls().len(), 1);
    assert!(!roster(&admin, &group).await.contains(&leaver.pubkey_hex()));
    let sealed = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    let LocationSeal::Sealed { event, .. } = sealed.seal else {
        panic!("the send after the eviction was applied is not sealed");
    };
    assert!(!reads(leaver, &event).await);
}

/// From the refusal until the eviction lands nothing is sealed for the
/// circle: once the wait the refusal earned is over, a send made before the
/// engine's re-armed deadline — when its preflight would stage nothing —
/// is deferred too, on both send paths, and the member who left is sent
/// nothing it could read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nothing_is_sealed_after_a_refused_eviction_before_its_re_armed_deadline() {
    let (admin, others, group) = a_departure_due().await;
    let leaver = &others[0];
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let send = through(&transport, &outbox, &clock, &FULL);
    let refused = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(
        matches!(refused.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
        "premise: every relay refused the eviction",
    );

    // The wait is over. MDK re-armed the eviction 10–50 ms of monotonic time
    // after the refusal, so these sends find its deadline still ahead — the
    // refusal holds them — or reached, when a send's preflight makes the
    // eviction again and the relay refuses it again. Either way nothing is
    // sealed or recorded, and the member who left is still listed.
    clock.set(61 * SECOND_MS);
    admin
        .session()
        .set_legacy_clock_for_test(ManualClock::ORIGIN + 61 * SECOND_MS);
    let after = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    let legacy = admin.circle.seal_location_for_test(&group, &fix()).await;
    assert!(
        matches!(after.seal, LocationSeal::Deferred(_))
            && legacy.is_err()
            && admin
                .session()
                .location_records_for_test(&group)
                .await
                .expect("the store is read")
                .is_empty(),
        "a location was sealed or recorded for a circle whose refused eviction is still unmade",
    );
    assert!(
        roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "premise: the eviction is still unmade",
    );
}

/// The epoch-rotation repair declines while a departure is unresolved, by its
/// own gate, before the engine is asked — inside a wait as outside one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_rotation_repair_inside_a_wait_stages_nothing() {
    let (admin, _others, group) = a_departure_due().await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(transport.calls().len(), 1, "premise: sent and refused");
    admin
        .session()
        .set_legacy_clock_for_test(ManualClock::ORIGIN + 30 * SECOND_MS);
    wait_out_the_engine(&admin, &group).await;

    let three_days_on =
        u64::try_from(chrono::Utc::now().timestamp()).expect("after 1970") + 3 * 24 * 3_600;
    let repaired = admin
        .circle
        .repair_rotation_for_test(&group, three_days_on)
        .await;
    assert!(
        matches!(
            repaired,
            Ok((
                haven_core::relay::fanout::RepairOutcome::Skipped(
                    haven_core::circle::SkipReason::PendingProposal
                ),
                None
            ))
        ),
        "the repair inside the wait was not declined by its own gate",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && transport.calls().is_empty(),
        "the repair inside the wait left the eviction staged or owed",
    );
}

/// After the wait a refusal earned is over, a full drive itself makes the
/// advance that stages the eviction again — a device that is not sending has
/// no other caller for it — on the wait's own schedule: one minute, doubling
/// to an hour. A relay that goes on refusing is sent six evictions in the
/// first hour and one an hour after, and none in between.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_drive_stages_a_refused_eviction_again_when_its_wait_is_over_and_never_before() {
    let (admin, _others, group) = a_departure_due().await;
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let drive = through(&transport, &outbox, &clock, &FULL);
    let _ = drive
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(transport.calls().len(), 1, "premise: sent and refused");

    let mut staged_at = Vec::new();
    let mut newest = newest_commit_row(&admin, &group).await;
    for minute in 1..=190_u64 {
        clock.set(minute * MINUTE_MS + SECOND_MS);
        // The engine arms a rolled-back eviction again on its own clock,
        // and announces when.
        wait_out_the_engine(&admin, &group).await;
        let _ = drive.resume(&admin.circle).await;
        let row = newest_commit_row(&admin, &group).await;
        if transport.calls().is_empty() {
            assert_eq!(
                row, newest,
                "a drive inside the wait staged the eviction and undid it (minute {minute})",
            );
        } else {
            staged_at.push(minute);
        }
        newest = row;
        assert!(staged_ref(&admin, &group).await.is_none());
    }
    assert_eq!(
        staged_at,
        [1, 3, 7, 15, 31, 63, 123, 183],
        "the eviction was not staged again on the wait's schedule",
    );
    assert!(outbox.handed().is_empty());

    // Never by a drive that only sends.
    clock.set(260 * MINUTE_MS);
    wait_out_the_engine(&admin, &group).await;
    let finish_only = DriveMode::FinishOnly;
    let _ = helpers::drive::within(&transport, &outbox, &clock, &finish_only, 2 * ROW_BUDGET_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().is_empty() && staged_ref(&admin, &group).await.is_none(),
        "a finish-only drive staged the eviction",
    );
}

/// The wait a refused eviction earned is something a full drive says when
/// to come back for: its hint is what is left of the wait. So the live
/// plane's drive task — which sleeps on that hint — wakes a drive when the
/// wait is over, and that drive stages the eviction again then: not before,
/// and not only when something else happens to wake the plane. A drive that
/// only sends stages nothing, and says nothing of the wait.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_drive_says_when_a_refused_evictions_wait_is_over_and_the_live_plane_wakes_for_it() {
    let (admin, _others, group) = a_departure_due().await;
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&group);
    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(transport.calls().len(), 1, "premise: sent and refused");

    clock.set(20 * SECOND_MS);
    wait_out_the_engine(&admin, &group).await;
    let waiting = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert_eq!(
        waiting.retry_after_ms,
        Some(40 * SECOND_MS),
        "a full drive inside a refused eviction's wait did not say when the wait is over",
    );
    let finish_only = DriveMode::FinishOnly;
    let narrow =
        helpers::drive::within(&transport, &outbox, &clock, &finish_only, 2 * ROW_BUDGET_MS)
            .resume(&admin.circle)
            .await;
    assert_eq!(
        narrow.retry_after_ms, None,
        "a drive that only sends asked to be woken for an eviction it cannot stage",
    );
    // Two seconds from the wait's end the hint is the drive task's own
    // floor, not two seconds: the wait is never a reason to spin.
    clock.set(58 * SECOND_MS);
    let nearly = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert_eq!(
        nearly.retry_after_ms,
        Some(5 * SECOND_MS),
        "a full drive asked to be woken sooner than the floor for a wait about to end",
    );
    clock.set(20 * SECOND_MS);

    // The live plane's drive task sleeps on that hint.
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Arc::new(Recorder::acking(true)) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    processor.for_test().set_background_burst(false);
    processor.for_test().drive_due().await;
    assert!(transport.calls().is_empty(), "premise: inside the wait");
    {
        let timer = processor.drive_due_again();
        tokio::pin!(timer);
        clock.set(59 * SECOND_MS);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_pending(),
            "the drive woke itself before the wait was over",
        );
        clock.set(60 * SECOND_MS);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_ready(),
            "the drive did not wake itself when the wait was over",
        );
    }
    wait_out_the_engine(&admin, &group).await;
    processor.for_test().drive_due().await;
    assert_eq!(
        transport.calls().len(),
        1,
        "the drive its own timer woke did not stage the eviction again and send it",
    );
}

// ── Rate ─────────────────────────────────────────────────────────────────────

/// A relay that never answers is called on one schedule, whatever asks: a
/// location send, a polled event and a live-plane drive every minute for two
/// hours — each through the same stored records and the process's one
/// driving registry, over transports of their own — add no call. The calls
/// land in minutes 1, 2, 4, 8, 16, 32, 64 and 124 after the first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_silent_relay_is_called_on_one_schedule_whatever_sends_polls_or_drives() {
    let (admin, others, group, entries, _) = a_hand_over_awaiting(&[(ONE, Answer::Silent)]).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let live_transport = Arc::new(ScriptedFanout::default());
    let live = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&live_transport) as Arc<dyn FanoutSend>,
            publisher: Arc::new(Recorder::acking(true)) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    live.for_test().set_background_burst(false);
    let polled = sealed_by(&others[0], &group, 12.5).await;
    let plane = through(&entries, &outbox, &clock, &FULL);

    let (mut called_in, mut by_entries, mut by_live) = (Vec::new(), 0, 0);
    for minute in 1..=125_u64 {
        clock.set(minute * MINUTE_MS);
        let mut calls = 0;
        for turn in 0..3 {
            // Whoever comes first in a minute takes the relay's one call.
            match (turn + minute) % 3 {
                0 => {
                    let sent = plane
                        .seal_location(&admin.circle, &group, &fix())
                        .await
                        .expect("the send runs");
                    assert!(matches!(
                        sent.seal,
                        LocationSeal::Deferred(SendHeld::AwaitingRelays)
                    ));
                }
                1 => {
                    let _ = plane
                        .ingest_for_poll(&admin.circle, &polled)
                        .await
                        .expect("the poll runs");
                }
                _ => live.for_test().drive_due().await,
            }
            let (entry, drive) = (entries.calls().len(), live_transport.calls().len());
            by_entries += entry;
            by_live += drive;
            calls += entry + drive;
        }
        assert!(calls <= 1, "a relay was called twice in one minute");
        if calls == 1 {
            called_in.push(minute);
        }
    }
    assert_eq!(
        called_in,
        [1, 2, 4, 8, 16, 32, 64, 124],
        "a send, a poll or a drive called the relay outside its schedule",
    );
    assert!(
        by_entries > 0 && by_live > 0,
        "the two planes did not share the schedule: one of them never made a call",
    );
    assert_eq!(records_of(&admin, &group).await[0].mls, FanoutMls::Pending);
}

// ── Process death ────────────────────────────────────────────────────────────

fn db_of(member: &CircleMember) -> (std::path::PathBuf, storage_sqlite::SqlCipherKey) {
    (
        StorageConfig::new(member.dir.path()).database_path(),
        StorageConfig::test_sqlcipher_key().expect("test key"),
    )
}

/// The record the send's hold wrote for the preflight's eviction survives a
/// process that dies before its first call: the next process's drive sends
/// those bytes, and they are applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_between_the_sends_record_and_its_first_call_sends_the_same_bytes_afterwards() {
    let (admin, others, group) = a_departure_due().await;
    let transport = ScriptedFanout::default();
    // The relay could not be had: the record is written and nothing is sent.
    transport.answer(ONE, [Answer::Busy, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let held = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(matches!(
        held.seal,
        LocationSeal::Deferred(SendHeld::AwaitingRelays)
    ));
    let recorded = records_of(&admin, &group).await.remove(0);
    assert_eq!(recorded.statuses, [FanoutTargetStatus::NotAttempted]);
    assert!(transport.calls().is_empty());

    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "the recorded eviction was not restored at the open",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    let calls = transport.calls();
    assert!(
        calls.len() == 1 && calls[0].payload == recorded.payload,
        "the next process did not send the recorded bytes once",
    );
    assert!(!roster(&admin, &group)
        .await
        .contains(&others[0].pubkey_hex()));
}

/// A process that dies while the send's own drive has its first call out
/// leaves the attempt stored as begun. The next process records it as
/// possibly exposed — never a rollback — and sends the same bytes when the
/// relay is next due.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_during_the_sends_first_call_is_possibly_exposed_and_sent_again_on_schedule() {
    let (admin, _others, group) = a_departure_due().await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    transport.park();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    {
        let send = through(&transport, &outbox, &clock, &FULL);
        let location = fix();
        let out = send.seal_location(&admin.circle, &group, &location);
        tokio::pin!(out);
        tokio::select! {
            biased;
            _ = &mut out => panic!("the send finished while its relay call was parked"),
            () = transport.parked() => {}
        }
        // The process dies here: the call never returns.
    }
    transport.unpark();
    let begun = records_of(&admin, &group).await.remove(0);
    assert_eq!(begun.statuses, [FanoutTargetStatus::Attempting]);
    transport.calls();

    let admin = admin.reopen();
    let resume = through(&transport, &outbox, &clock, &FULL);
    let _ = resume.resume(&admin.circle).await;
    let stored = records_of(&admin, &group).await.remove(0);
    assert_eq!(
        (stored.mls, stored.statuses.as_slice()),
        (
            FanoutMls::Pending,
            &[FanoutTargetStatus::PossiblyExposed][..]
        ),
        "an attempt that never returned was not kept as possibly exposed",
    );
    assert!(transport.calls().is_empty(), "sent again before it was due");
    clock.set(31 * SECOND_MS);
    let _ = resume.resume(&admin.circle).await;
    let calls = transport.calls();
    assert!(calls.len() == 1 && calls[0].payload == begun.payload);
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "a commit a relay may hold was rolled back on a later refusal",
    );
}

/// The record cannot be written in the hold that staged the preflight's
/// eviction: the eviction is undone in that hold, unsent — nothing staged
/// without a record survives it, nothing is owed the legacy way — and the
/// next send records it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_the_sends_hold_cannot_record_is_undone_in_it_and_recorded_by_the_next() {
    let (admin, _others, group) = a_departure_due().await;
    let (db, key) = db_of(&admin);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let send = through(&transport, &outbox, &clock, &FULL);

    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    let unrecorded = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    assert!(
        matches!(unrecorded.seal, LocationSeal::Deferred(_))
            && staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && transport.calls().is_empty(),
        "an eviction with no record was left staged, owed or sent",
    );

    wait_out_the_engine(&admin, &group).await;
    let recorded = send
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(matches!(
        recorded.seal,
        LocationSeal::Deferred(SendHeld::AwaitingRelays)
    ));
    assert_eq!(transport.calls().len(), 1);
}

/// A process that dies after the entry's own drive confirmed the pending
/// commit and before anything else — here, a polled event Haven's screen
/// rejects before authentication, so the call ends right after its drive —
/// leaves the commit applied and nothing else: the next process seals.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_after_the_entrys_drive_confirmed_leaves_the_commit_applied_and_the_next_send_sealed(
) {
    let (admin, _others, group, transport, source) =
        a_hand_over_awaiting(&[(ONE, Answer::Silent)]).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let id = hex::encode(helpers::drive::ngid(&admin, &group).await);
    // Addressed to the circle, and of a kind the screen refuses.
    let rejected = nostr::EventBuilder::new(nostr::Kind::TextNote, "not a group message")
        .tag(nostr::Tag::parse(["h", &id]).expect("an h tag"))
        .sign_with_keys(&nostr::Keys::generate())
        .expect("signed");
    let polled = through(&transport, &outbox, &clock, &FULL)
        .ingest_for_poll(&admin.circle, &rejected)
        .await
        .expect("the call runs");
    assert!(!polled.errored && transport.calls().len() == 1);
    assert_eq!(
        polled.verdict,
        ReceiveOnlyOutcome::NoEvidence,
        "an event rejected before authentication moved or held the poll's cursor",
    );

    let admin = admin.reopen();
    assert_eq!(epoch(&admin, &group).await, source + 1);
    let sent = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(matches!(sent.seal, LocationSeal::Sealed { .. }));
    assert!(transport.calls().is_empty());
}

// ── Beside the legacy paths ──────────────────────────────────────────────────

/// A record the send entry made is left as it is by every path that makes
/// no commit and meets it — a send or a poll that makes no commit, and the
/// session's own resolvers: nothing resolves, sends or stages again what is
/// the driver's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_record_is_left_as_it_was_by_every_path_but_the_driver() {
    // A record of the send entry's making, awaiting its relay.
    let (admin, others, group) = a_departure_due().await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let entries = through(&transport, &outbox, &clock, &FULL);
    let _ = entries
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(transport.calls().len(), 1);
    let pending = staged_ref(&admin, &group).await.expect("staged");
    let standing = || async {
        let record = records_of(&admin, &group).await.remove(0);
        (
            record.event_id,
            record.mls,
            record.statuses,
            record.attempts,
        )
    };
    let before = standing().await;

    let peer = sealed_by(&others[1], &group, 7.5).await;
    assert!(admin
        .circle
        .ingest_for_test(&peer)
        .await
        .expect("the poll that makes no commit runs")
        .is_empty());
    assert!(matches!(
        admin.circle.seal_location_for_test(&group, &fix()).await,
        Err(CircleError::EngineHeld)
    ));
    assert!(matches!(
        admin.session().confirm_published(pending).await,
        Err(haven_core::nostr::NostrError::FanoutOwned)
    ));
    assert!(matches!(
        admin.session().publish_failed(pending).await,
        Err(haven_core::nostr::NostrError::FanoutOwned)
    ));
    assert_eq!(standing().await, before);
    assert!(
        staged_ref(&admin, &group).await == Some(pending)
            && transport.calls().is_empty()
            && outbox.handed().is_empty(),
        "a path that makes no commit resolved or sent a commit the send entry recorded",
    );
}

/// The relays `member`'s row says `group` is on.
async fn row_relays(member: &CircleMember, group: &GroupId) -> Vec<String> {
    member
        .circle
        .get_circle(group)
        .await
        .expect("read the circle")
        .expect("the circle exists")
        .circle
        .relays
}

/// A peer's change of the circle's relays taken in through the poll's
/// driver entry (`ingest_driven`) moves the circle's row, so its sends — and
/// the live plane's REQs — go where the circle now lives.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peers_relay_change_ingested_through_the_driver_moves_the_row() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let member = &others[0];
    let update = admin
        .circle
        .update_relays_for_test(&group, &[TWO.to_string()])
        .await
        .expect("the admin changes the circle's relays");
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .ingest_for_poll(&member.circle, &update)
        .await
        .expect("the commit is ingested");
    assert_eq!(
        row_relays(member, &group).await,
        [TWO.to_string()],
        "a peer's change of relays taken in through the driver left the row where it was",
    );
}

/// A hand-over awaiting its relay, and behind it the new admin's change of
/// the circle's relays from `ONE` to `TWO`, which the old admin's engine
/// holds until its own commit is resolved. The relay now answers.
async fn a_relay_change_waiting_behind_a_hand_over() -> (CircleMember, GroupId, ScriptedFanout) {
    let (admin, others, group, transport, _) = a_hand_over_awaiting(&[(ONE, Answer::Silent)]).await;
    let frozen = records_of(&admin, &group).await.remove(0);
    let heir = &others[1];
    applies(
        heir,
        &Event::from_json(&frozen.payload).expect("the hand-over"),
    )
    .await;
    let update = heir
        .circle
        .update_relays_for_test(&group, &[TWO.to_string()])
        .await
        .expect("the new admin changes the circle's relays");
    admin
        .session()
        .process_event_settled_for_test(&update)
        .await
        .expect("the change is ingested");
    assert_eq!(
        row_relays(&admin, &group).await,
        [ONE.to_string()],
        "premise: the change waits behind the pending hand-over",
    );
    transport.answer(ONE, [Answer::Accepted]);
    (admin, group, transport)
}

/// A peer's change of relays the engine replays inside the confirm a
/// location send's own drive makes moves the row, and the location that
/// send seals is addressed to where the circle now lives.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peers_relay_change_replayed_inside_a_sends_drive_moves_the_row_and_the_seal() {
    let (admin, group, transport) = a_relay_change_waiting_behind_a_hand_over().await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    let sent = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(
        transport.calls().len(),
        1,
        "premise: the hand-over was sent"
    );
    assert_eq!(
        row_relays(&admin, &group).await,
        [TWO.to_string()],
        "a peer's change of relays replayed inside a send's drive left the row where it was",
    );
    let LocationSeal::Sealed { relays, .. } = sent.seal else {
        panic!("the send whose drive applied its commit was not sealed");
    };
    assert_eq!(
        relays,
        [TWO.to_string()],
        "the location was addressed to the relays the circle left",
    );
}

/// A peer's change of relays the engine replays inside the confirm a resume
/// makes moves the row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_peers_relay_change_replayed_inside_a_resume_moves_the_row() {
    let (admin, group, transport) = a_relay_change_waiting_behind_a_hand_over().await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert_eq!(
        transport.calls().len(),
        1,
        "premise: the hand-over was sent"
    );
    assert_eq!(
        row_relays(&admin, &group).await,
        [TWO.to_string()],
        "a peer's change of relays replayed inside a resume left the row where it was",
    );
}

/// A change's answer carries clock evidence only when no relay took its
/// commit and a relay's `invalid:`, `blocked:` or unprefixed refusal blamed the
/// timestamp, its relays' directions merged — the rule the legacy publish
/// follows (`clock_skew::classify_publish_outcome`): one refusal "in the
/// future" beside another relay's acknowledgement is no clock evidence; two
/// refusals in opposite directions are `Unspecified`; and a relay that took
/// it on its own leaves none.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_a_relay_refuses_for_its_timestamp_is_answered_with_the_clock_evidence() {
    use haven_core::relay::clock_skew::DeviceClockComplaint;
    use haven_core::relay::fanout::Publishing;
    use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};

    const AHEAD: &str = "invalid: event creation date is in the future";
    const BEHIND: &str = "invalid: event is too old";
    for (answers, expected) in [
        ([Some(AHEAD), None], None),
        (
            [Some(AHEAD), Some(BEHIND)],
            Some(DeviceClockComplaint::Unspecified),
        ),
        (
            [Some(AHEAD), Some(AHEAD)],
            Some(DeviceClockComplaint::Ahead),
        ),
        ([None, None], None),
    ] {
        let relays = [ScriptedRelay::start(), ScriptedRelay::start()];
        for (relay, refusal) in relays.iter().zip(answers) {
            if let Some(text) = refusal {
                relay.on_publish(move |_| Verdict::Refuse(text.to_string()));
            }
        }
        let fx = setup_circle(3, &[relays[0].url(), relays[1].url()]).await;
        let (admin, others, group) = split(fx);
        let transport = haven_core::relay::RelayManager::new().fanout_transport();
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        let outcome = Publishing {
            fanout: &transport,
            publisher: &outbox,
            clock: clock.as_ref(),
            deadline_ms: None,
            mode: &FULL,
        }
        .remove_members(&admin.circle, &group, &[others[0].pubkey_hex()])
        .await
        .expect("the change is driven");
        assert_eq!(
            outcome.clock_rejected, expected,
            "the change's answer lost, or invented, a relay's clock verdict ({answers:?})",
        );
    }
}

/// A circle with a second admin whose first admin holds a departed member's
/// eviction that every relay refused: the refusal's wait is running.
async fn a_two_admin_circle_inside_a_refusal_wait() -> (
    CircleMember,
    Vec<CircleMember>,
    GroupId,
    ScriptedFanout,
    Arc<ManualClock>,
) {
    let fx = setup_circle(3, &[ONE]).await;
    let promoted = fx
        .admin()
        .circle
        .admin_handoff_for_test(&fx.group, &fx.members[2].keys.public_key())
        .await
        .expect("the hand-over is staged");
    applies(&fx.members[1], &promoted).await;
    applies(&fx.members[2], &promoted).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    make_a_departure_due(&admin, &others[1], &group, &leave).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert_eq!(transport.calls().len(), 1, "premise: sent and refused");
    admin
        .session()
        .set_legacy_clock_for_test(ManualClock::ORIGIN + 30 * SECOND_MS);
    clock.set(30 * SECOND_MS);
    wait_out_the_engine(&admin, &group).await;
    (admin, others, group, transport, clock)
}

/// A leave asked of the driver inside the wait a refused eviction earned, by
/// an admin with a second admin beside it — `leave_driven`, then
/// `resume_leave_driven`, both in a claimed foreground as the app calls them:
/// inside the wait the leave is neither lost nor made twice — its intent
/// stands, nothing is staged, recorded, queued or sent, and every send for
/// the circle is held as leaving — and once the wait is over the eviction,
/// the step down and the leave's proposal are each made once, and the leave
/// stands proposed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_inside_a_refusal_wait_is_neither_lost_nor_made_twice_and_goes_on_after_it() {
    use haven_core::relay::fanout::LeaveStatus;
    let (admin, others, group, transport, clock) = a_two_admin_circle_inside_a_refusal_wait().await;
    let me = admin.keys.public_key();
    let outbox = Recorder::acking(true);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let rows_before = newest_commit_row(&admin, &group).await;

    let asked = driver
        .leave(&admin.circle, &group, &me)
        .await
        .expect("the leave is asked");
    for tick in [40, 50, 59] {
        wait_out_the_engine(&admin, &group).await;
        clock.set(tick * SECOND_MS);
        let carried = driver
            .resume_leave(&admin.circle, &group, &me)
            .await
            .expect("the leave is carried on");
        assert_eq!(
            carried.status,
            LeaveStatus::Pending,
            "inside the wait the leave did not stand pending"
        );
        let held = driver
            .seal_location(&admin.circle, &group, &fix())
            .await
            .expect("the send runs");
        assert!(
            matches!(held.seal, LocationSeal::Deferred(SendHeld::Leaving)),
            "a location was sealed for a circle being left",
        );
    }
    let inside = (
        asked.status == LeaveStatus::Pending,
        transport.calls().len(),
        staged_ref(&admin, &group).await.is_some(),
        records_of(&admin, &group).await.len(),
        newest_commit_row(&admin, &group).await == rows_before,
        admin
            .session()
            .queued_intent_count_for_test(&group)
            .await
            .expect("the queue is read"),
    );
    assert_eq!(
        inside,
        (true, 0, false, 0, true, 0),
        "inside the wait the leave staged, recorded, queued or sent something",
    );
    assert!(admin
        .circle
        .leave_intent_at(&group)
        .expect("read")
        .is_some());

    // The wait is over.
    clock.set(61 * SECOND_MS);
    admin
        .session()
        .set_legacy_clock_for_test(ManualClock::ORIGIN + 61 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let mut status = LeaveStatus::Pending;
    for _ in 0..4 {
        wait_out_the_engine(&admin, &group).await;
        status = driver
            .resume_leave(&admin.circle, &group, &me)
            .await
            .expect("the leave is carried on")
            .status;
        if status == LeaveStatus::Proposed {
            break;
        }
    }
    let sent = transport.calls();
    let mut ids: Vec<_> = sent.iter().map(|call| call.event_id).collect();
    ids.sort();
    ids.dedup();
    assert!(
        status == LeaveStatus::Proposed
            && !roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex())
            && ids.len() == sent.len()
            && sent.len() == 3,
        "after the wait the eviction, the step down and the proposal were not each sent \
         once (sent {}), or the leave does not stand proposed",
        sent.len(),
    );
    assert_eq!(
        admin
            .session()
            .queued_intent_count_for_test(&group)
            .await
            .expect("the queue is read"),
        0,
        "a step the leave asked for is still queued: it could be made a second time",
    );
}

/// The Android service's cycle, its exact calls: a polled event taken in and
/// the stored records driven, both with `foreground: false` — the mode that
/// makes no new commit. With a departed member's removal owed, the cycle
/// makes nothing of it: no relay is called, nothing is staged or recorded,
/// and the member is still listed; the circle's driven seal is held for the
/// departure meanwhile, so nothing is sealed at the epoch that member reads.
/// The removal waits for a foreground: the first full drive makes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_fgs_cycles_finish_only_calls_leave_an_owed_removal_to_a_foreground_and_hold_sends() {
    let (admin, others, group) = a_departure_due().await;
    let leaver = &others[0];
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let fgs = through(&transport, &outbox, &clock, &DriveMode::FinishOnly);

    for tick in 0..3_u32 {
        wait_out_the_engine(&admin, &group).await;
        let polled = sealed_by(&others[1], &group, f64::from(tick).mul_add(0.5, 30.0)).await;
        let _ = fgs
            .ingest_for_poll(&admin.circle, &polled)
            .await
            .expect("the cycle takes the event in");
        let _ = fgs.resume(&admin.circle).await;
        let held = fgs
            .seal_location(&admin.circle, &group, &fix())
            .await
            .expect("the cycle's seal is answered");
        assert!(
            matches!(held.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
            "the cycle sealed a location while the departed member's removal was owed",
        );
    }
    assert!(
        transport.calls().is_empty()
            && staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && outbox.handed().is_empty()
            && roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "a cycle that makes no new commit made, recorded or sent the removal",
    );

    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().len() == 1
            && !roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "the first full drive did not make the owed removal",
    );
}

/// Inside the wait a refused eviction earned, a leave asked while the engine
/// cannot be had — the refused eviction's rollback left its commit
/// unretired, so the engine is called for nothing until it is — is waited
/// out, not asked of the engine: it stands pending, told to come back when
/// this circle's own wait ends, its intent kept, nothing queued or sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_inside_a_refusal_wait_waits_it_out_while_the_engine_cannot_be_had() {
    use haven_core::nostr::mls::storage::set_commit_retirement_fault_for_test;
    use haven_core::nostr::NostrError;
    use haven_core::relay::fanout::LeaveStatus;
    let fx = setup_circle(3, &[ONE]).await;
    let promoted = fx
        .admin()
        .circle
        .admin_handoff_for_test(&fx.group, &fx.members[2].keys.public_key())
        .await
        .expect("the hand-over is staged");
    applies(&fx.members[1], &promoted).await;
    applies(&fx.members[2], &promoted).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    make_a_departure_due(&admin, &others[1], &group, &leave).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    // Recorded with no room to send, so its commit is known before the
    // refusal rolls it back with its retirement failing.
    let _ = helpers::drive::within(&transport, &outbox, &clock, &FULL, 0)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    let [record] = <[_; 1]>::try_from(records_of(&admin, &group).await)
        .unwrap_or_else(|_| panic!("premise: the eviction is recorded"));
    let (db, key) = db_of(&admin);
    set_commit_retirement_fault_for_test(&db, &key, record.event_id.as_bytes(), true).expect("arm");
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert_eq!(transport.calls().len(), 1, "premise: sent and refused");
    assert!(
        matches!(
            admin.session().advance_convergence(&group).await,
            Err(NostrError::EngineHeld)
        ),
        "premise: the engine cannot be had",
    );
    clock.set(30 * SECOND_MS);
    let me = admin.keys.public_key();
    let asked = through(&transport, &outbox, &clock, &FULL)
        .leave(&admin.circle, &group, &me)
        .await
        .expect("the leave is answered");
    set_commit_retirement_fault_for_test(&db, &key, record.event_id.as_bytes(), false)
        .expect("disarm");
    assert_eq!(
        (asked.status, asked.retry_after_ms),
        (LeaveStatus::Pending, Some(30 * SECOND_MS)),
        "a leave inside the wait was not waited out with this circle's own wait",
    );
    assert!(
        transport.calls().is_empty()
            && admin
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("the queue is read")
                == 0
            && admin
                .circle
                .leave_intent_at(&group)
                .expect("read")
                .is_some(),
        "a leave inside the wait was asked of the engine, or lost its intent",
    );
}

/// Inside a refusal wait that no eviction earned — a change of the circle's
/// relays every relay refused — a leave is not waited out: the engine has
/// nothing scheduled to stage ahead of it, so the leave's first step is
/// sent at once and its intent kept.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_inside_a_refusal_wait_no_eviction_earned_goes_on_at_once() {
    use haven_core::relay::fanout::EvolutionStatus;
    let fx = setup_circle(3, &[ONE]).await;
    helpers::stranded::co_admin(&fx).await;
    let (_admin, others, group) = split(fx);
    let co = &others[0];
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let changed = through(&transport, &outbox, &clock, &FULL)
        .update_relays(&co.circle, &group, &[TWO.to_string()])
        .await
        .expect("the change is answered");
    assert!(
        changed.status == EvolutionStatus::RolledBack && transport.calls().len() == 1,
        "premise: the change was sent, refused and rolled back",
    );
    clock.set(SECOND_MS);
    transport.answer(ONE, [Answer::Accepted, Answer::Accepted, Answer::Accepted]);
    let me = co.keys.public_key();
    let _ = through(&transport, &outbox, &clock, &FULL)
        .leave(&co.circle, &group, &me)
        .await
        .expect("the leave is answered");
    assert!(
        !transport.calls().is_empty() && co.circle.leave_intent_at(&group).expect("read").is_some(),
        "a leave inside a refusal wait with no eviction scheduled was waited out",
    );
}

/// A Welcome an invitee's own inbox relay refuses with words about its
/// timestamp is no evidence about this device's clock: an invitee's relay is
/// not one the user chose, and its answer reaches the Welcome's record as
/// taken or not, never as a clock verdict on the change.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invitees_inbox_refusing_a_welcome_for_its_timestamp_is_no_clock_evidence() {
    use haven_core::circle::MemberKeyPackage;
    use haven_core::relay::fanout::Publishing;
    use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};

    let (group_relay, inbox) = (ScriptedRelay::start(), ScriptedRelay::start());
    inbox.on_publish(|_| {
        Verdict::Refuse("invalid: event creation date is in the future".to_string())
    });
    let fx = setup_circle(2, &[group_relay.url()]).await;
    let (admin, _others, group) = split(fx);
    let invitee = CircleMember::new();
    let inbox_relays = vec![inbox.url().to_string()];
    let package = MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            invitee.session(),
            &invitee.keys,
            &inbox_relays,
        )
        .await,
        inbox_relays,
        nip65_relays: Vec::new(),
    };
    let relay_mgr = haven_core::relay::RelayManager::new();
    let transport = relay_mgr.fanout_transport();
    let clock = ManualClock::at(0);
    let outcome = Publishing {
        fanout: &transport,
        publisher: &relay_mgr,
        clock: clock.as_ref(),
        deadline_ms: None,
        mode: &FULL,
    }
    .add_members(&admin.circle, &group, &[package])
    .await
    .expect("the invite is driven");
    assert!(
        inbox.offers() > 0 && inbox.published().is_empty(),
        "premise: the invitee's inbox was offered the Welcome and refused it",
    );
    assert_eq!(
        outcome.clock_rejected, None,
        "an invitee's inbox refusing a Welcome raised a clock verdict",
    );
}

/// A promotion of this device the engine takes in between the leave's plan
/// and its proposal — still a pending input when the plan reads the admin
/// set, applied by the engine's own preflight inside the proposal's call —
/// does not end the leave: the driver reads its plan again with the intent
/// kept, steps down, and proposes once; every send for the circle is held
/// throughout.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_promotion_taken_in_between_the_plan_and_the_proposal_is_stepped_down_from() {
    use haven_core::relay::fanout::LeaveStatus;
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let leaver = &others[0];
    let promotion = admin
        .circle
        .admin_handoff_for_test(&group, &leaver.keys.public_key())
        .await
        .expect("the admin promotes the leaver");
    let _ = leaver
        .session()
        .process_event(&promotion)
        .await
        .expect("the leaver takes the promotion in");
    assert!(
        leaver.session().has_pending_inputs_for_test(&group).await,
        "premise: the promotion waits as a pending input when the plan reads the admins",
    );
    // Its deadline passed, so the proposal's own preflight settles it.
    wait_out_the_engine(leaver, &group).await;

    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let me = leaver.keys.public_key();
    let mut status = driver
        .leave(&leaver.circle, &group, &me)
        .await
        .expect("the leave is answered")
        .status;
    for _ in 0..3 {
        if status == LeaveStatus::Proposed {
            break;
        }
        let held = driver
            .seal_location(&leaver.circle, &group, &fix())
            .await
            .expect("the send runs");
        assert!(matches!(
            held.seal,
            LocationSeal::Deferred(SendHeld::Leaving)
        ));
        status = driver
            .resume_leave(&leaver.circle, &group, &me)
            .await
            .expect("the leave is carried on")
            .status;
    }
    let sent = transport.calls();
    let mut ids: Vec<_> = sent.iter().map(|call| call.event_id).collect();
    ids.sort();
    ids.dedup();
    assert!(
        status == LeaveStatus::Proposed
            && leaver
                .circle
                .leave_intent_at(&group)
                .expect("read")
                .is_some()
            && ids.len() == sent.len()
            && sent.len() == 2,
        "the leave did not step down and propose once after a promotion it took in \
         mid-call (sent {}, {status:?})",
        sent.len(),
    );
    let held = driver
        .seal_location(&leaver.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(matches!(
        held.seal,
        LocationSeal::Deferred(SendHeld::Leaving)
    ));
}

/// Two leave presses on one circle at once — and a press racing the leave's
/// carrying-on — make one intent and one proposal: the proposal is sent once,
/// nothing is queued, and both calls answer the leave as proposed or still
/// coming.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn racing_leave_calls_make_one_intent_and_one_proposal() {
    use haven_core::relay::fanout::LeaveStatus;
    for press_races_the_carry_on in [false, true] {
        let fx = setup_circle(3, &[ONE]).await;
        let (_admin, others, group) = split(fx);
        let leaver = &others[0];
        let me = leaver.keys.public_key();
        let transport = ScriptedFanout::default();
        transport.answer(ONE, [Answer::Accepted]);
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        let driver = through(&transport, &outbox, &clock, &FULL);
        let (first, second) = if press_races_the_carry_on {
            tokio::join!(
                driver.leave(&leaver.circle, &group, &me),
                driver.resume_leave(&leaver.circle, &group, &me)
            )
        } else {
            tokio::join!(
                driver.leave(&leaver.circle, &group, &me),
                driver.leave(&leaver.circle, &group, &me)
            )
        };
        let statuses = [
            first.expect("the first call is answered").status,
            second.expect("the second call is answered").status,
        ];
        // A carry-on that ran before the press found no leave to carry on.
        let _ = driver.resume_leave(&leaver.circle, &group, &me).await;
        let sent = transport.calls();
        let mut ids: Vec<_> = sent.iter().map(|call| call.event_id).collect();
        ids.sort();
        ids.dedup();
        assert!(
            statuses.iter().all(|status| matches!(
                status,
                LeaveStatus::Proposed | LeaveStatus::Pending | LeaveStatus::NotLeaving
            )) && statuses.contains(&LeaveStatus::Proposed)
                && sent.len() == 1
                && ids.len() == 1
                && leaver
                    .circle
                    .leave_intent_at(&group)
                    .expect("read")
                    .is_some()
                && leaver
                    .session()
                    .queued_intent_count_for_test(&group)
                    .await
                    .expect("the queue is read")
                    == 0,
            "racing leave calls made the proposal more than once, or lost the leave \
             (press races the carry-on: {press_races_the_carry_on}; {statuses:?}, sent {})",
            sent.len(),
        );
    }
}

/// The circle's only admin pressing Leave twice at once hands the circle over
/// once. The second press's plan can be read before the first press's
/// hand-over lands and be acted on after it is confirmed: that hand-over,
/// made again, names the admins the circle already has — a commit for
/// nothing, on the wire — and is not made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hand_over_planned_before_another_landed_is_not_made_again() {
    use haven_core::circle::LeavePlan;
    use haven_core::relay::fanout::EvolutionStatus;

    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let me = admin.keys.public_key();
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let LeavePlan::AdminHandoff { successor } = admin
        .circle
        .plan_leave(&group, &me)
        .await
        .expect("the plan is read")
    else {
        panic!("premise: the only admin hands the circle over first");
    };
    let first = driver
        .admin_handoff(&admin.circle, &group, &successor)
        .await
        .expect("the first hand-over runs");
    assert!(
        first.status == EvolutionStatus::Confirmed && transport.call_count() == 1,
        "premise: the first hand-over was made and confirmed",
    );
    let epoch = admin
        .session()
        .epoch(&group)
        .await
        .expect("the epoch is read");
    transport.calls();

    let again = driver
        .admin_handoff(&admin.circle, &group, &successor)
        .await
        .expect("the stale plan's hand-over runs");
    assert!(
        transport.call_count() == 0
            && admin
                .session()
                .epoch(&group)
                .await
                .expect("the epoch is read")
                == epoch,
        "a hand-over to a member already an admin was made again ({:?})",
        again.status,
    );
    assert!(
        again.status == EvolutionStatus::AlreadySo,
        "a hand-over already made was not answered as already so — or was answered as a \
         relay's acknowledgement",
    );

    // The same for the step-down that follows it.
    let down = driver
        .self_demote(&admin.circle, &group)
        .await
        .expect("the step-down runs");
    assert!(
        down.status == EvolutionStatus::Confirmed && transport.call_count() == 1,
        "premise: the step-down was made and confirmed",
    );
    let epoch = admin
        .session()
        .epoch(&group)
        .await
        .expect("the epoch is read");
    transport.calls();
    let down_again = driver
        .self_demote(&admin.circle, &group)
        .await
        .expect("the stale plan's step-down runs");
    assert!(
        transport.call_count() == 0
            && admin
                .session()
                .epoch(&group)
                .await
                .expect("the epoch is read")
                == epoch
            && down_again.status == EvolutionStatus::AlreadySo,
        "a step-down of a device no longer an admin was made again",
    );
}

/// A change of the circle's admins asked for in the foreground records no
/// commit when that foreground ends while the change waits in its hand-back:
/// the mode is asked again after it, as every staging hold asks it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_admin_change_whose_foreground_ends_in_its_hand_back_records_no_commit() {
    use haven_core::circle::LeavePlan;
    use haven_core::relay::fanout::{EvolutionStatus, ModeSource};
    use std::sync::atomic::{AtomicBool, Ordering};

    struct EndsInTheHandBack(Arc<AtomicBool>);
    impl ModeSource for EndsInTheHandBack {
        fn mode(&self) -> DriveMode {
            if self.0.load(Ordering::SeqCst) {
                DriveMode::FinishOnly
            } else {
                DriveMode::Full
            }
        }
        fn stands(&self) -> bool {
            !self.0.load(Ordering::SeqCst)
        }
    }

    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let LeavePlan::AdminHandoff { successor } = admin
        .circle
        .plan_leave(&group, &admin.keys.public_key())
        .await
        .expect("the plan is read")
    else {
        panic!("premise: the only admin hands the circle over first");
    };
    let ended = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&ended);
    admin
        .session()
        .during_next_hand_back_for_test(move || flag.store(true, Ordering::SeqCst));
    let source = EndsInTheHandBack(ended);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &source);
    let changed = driver
        .admin_handoff(&admin.circle, &group, &successor)
        .await;
    assert!(
        !matches!(
            changed.as_ref().map(|outcome| outcome.status),
            Ok(EvolutionStatus::Confirmed | EvolutionStatus::Unresolved)
        ) && transport.calls().is_empty()
            && staged_ref(&admin, &group).await.is_none(),
        "an admin change whose foreground ended in its hand-back was recorded or sent",
    );
}

/// What an outsider can make of the poll's ingest. A kind-445 addressed to the
/// circle that no member wrote — its signature forged, its content garbage
/// under a valid signature, or a genuine ciphertext of another circle re-tagged
/// and re-signed — is answered by the poll entry without an error and without
/// holding the poll's cursor: nothing from outside the circle can make the
/// poll come back for an event forever.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_outsider_authored_group_event_makes_the_poll_err_or_hold() {
    use base64::Engine as _;
    use nostr::{EventBuilder, Keys, Kind, Tag};
    let fx = setup_circle(2, &[ONE]).await;
    let other = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let h = hex::encode(helpers::drive::ngid(&admin, &group).await);
    let outsider = Keys::generate();
    let addressed = |content: String| {
        EventBuilder::new(Kind::Custom(445), content)
            .tag(Tag::parse(["h", &h]).expect("an h tag"))
            .sign_with_keys(&outsider)
            .expect("signed")
    };
    let garbage = addressed(base64::engine::general_purpose::STANDARD.encode([0x5a_u8; 96]));
    let not_base64 = addressed("not a ciphertext".to_string());
    let elsewhere = sealed_by(&other.members[1], &other.group, 3.0).await;
    let retagged = addressed(elsewhere.content.clone());
    let genuine = sealed_by(&others[0], &group, 4.0).await;
    let mut forged_json: serde_json::Value =
        serde_json::from_str(&genuine.as_json()).expect("json");
    forged_json["content"] =
        serde_json::Value::String(base64::engine::general_purpose::STANDARD.encode([7_u8; 96]));
    let forged = Event::from_json(forged_json.to_string()).expect("parses unverified");

    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let poll = through(&transport, &outbox, &clock, &FULL);
    for (what, event) in [
        ("garbage under a valid signature", &garbage),
        ("content that is no ciphertext", &not_base64),
        ("another circle's ciphertext re-tagged", &retagged),
        ("a forged signature", &forged),
    ] {
        let answered = poll.ingest_for_poll(&admin.circle, event).await;
        assert!(
            matches!(&answered, Ok(outcome) if outcome.verdict != ReceiveOnlyOutcome::Deferred),
            "an outsider's event ({what}) made the poll err or hold its cursor: {:?}",
            answered.as_ref().map(|outcome| outcome.verdict),
        );
    }
}

/// A member's self-update, applied by the member and by `others`.
async fn moved_on_by(member: &CircleMember, others: &[&CircleMember], group: &GroupId) -> Event {
    let (event, pending) = helpers::stranded::staged(
        &member
            .session()
            .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
                group_id: group.clone(),
            })
            .await
            .expect("the member updates itself"),
    );
    member
        .session()
        .confirm_published(pending)
        .await
        .expect("the member applies it");
    for other in others {
        applies(other, &event).await;
    }
    event
}

/// Group events a member sealed that this device cannot apply make the poll
/// neither err nor hold its cursor: one from an epoch past the retention
/// window, and one whose outer layer peels around an inner message nobody
/// can open. One from an epoch this device has not reached yet may hold the
/// cursor — that is legitimate, it can be applied once the commit before it
/// arrives — but is no error either.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_member_sealed_event_this_device_cannot_apply_makes_the_poll_err() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let member = &others[0];
    let past = sealed_by(member, &group, 1.0).await;
    for _ in 0..6 {
        let _ = moved_on_by(member, &[&admin], &group).await;
    }
    assert_eq!(
        epoch(&admin, &group).await,
        epoch(member, &group).await,
        "premise: both moved six epochs past the first fix",
    );
    let malformed = member
        .session()
        .forge_malformed_inner_445_for_test(&group)
        .await
        .expect("an outer layer around an inner message nobody can open");
    let _ = moved_on_by(member, &[], &group).await;
    let future = sealed_by(member, &group, 2.0).await;

    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let poll = through(&transport, &outbox, &clock, &FULL);
    for (what, event, may_hold) in [
        ("from an epoch past the retention window", &past, false),
        ("an inner message nobody can open", &malformed, false),
        ("from an epoch not reached yet", &future, true),
    ] {
        let answered = poll.ingest_for_poll(&admin.circle, event).await;
        assert!(
            matches!(
                &answered,
                Ok(outcome) if may_hold || outcome.verdict != ReceiveOnlyOutcome::Deferred
            ),
            "a member's event ({what}) made the poll err, or hold its cursor when it may \
             not: {:?}",
            answered.as_ref().map(|outcome| outcome.verdict),
        );
    }
}

/// A peer's fix that waited behind this device's pending commit is replayed
/// when every relay refuses that commit and the send entry's own drive rolls
/// it back — and reaches the seal's answer (`SealOutcome::replayed`) and the
/// last-known store, so the fix is not lost with the commit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fix_replayed_by_a_rollback_inside_a_seals_drive_reaches_its_answer() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let witness = &others[0];
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    // Recorded with no room to send: the commit is pending and never tried.
    let _ = helpers::drive::within(&transport, &outbox, &clock, &FULL, 0)
        .admin_handoff(&admin.circle, &group, &others[1].keys.public_key())
        .await
        .expect("the hand-over is recorded");
    assert!(
        transport.calls().is_empty() && staged_ref(&admin, &group).await.is_some(),
        "premise: a pending commit nobody was sent"
    );
    // Taken in by the engine alone, so no entry drives the commit first.
    let waiting = sealed_by(witness, &group, 48.25).await;
    let _ = admin
        .session()
        .process_event(&waiting)
        .await
        .expect("the fix is taken in");
    assert!(
        !stored_fix(&admin, &group, witness, 48.25).await,
        "premise: the engine holds the fix behind the pending commit",
    );

    let sealed = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send runs");
    assert!(
        transport.calls().len() == 1 && staged_ref(&admin, &group).await.is_none(),
        "premise: the commit was sent, refused and rolled back",
    );
    assert!(
        has_fix(&sealed.replayed, witness, 48.25),
        "the fix the rollback replayed is not in the seal's answer",
    );
    assert!(
        stored_fix(&admin, &group, witness, 48.25).await,
        "the fix the rollback replayed is not in the last-known store",
    );
}
