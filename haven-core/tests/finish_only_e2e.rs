//! The fanout driver's finish-only mode (Security Rule 13).
//!
//! A call in [`DriveMode::FinishOnly`] begins nothing: it sends the frozen
//! bytes of a pending commit a relay may already hold to each relay it has
//! been sent to before that is due, stores what each answered, and — with a
//! whole fold's budget left
//! — confirms a commit whose stored record holds an acknowledgement, unless
//! the commit changes the circle's relays. Each thing it must never do has
//! a test here that fails when the mode is ignored at that site; what a
//! death around its confirm costs is measured first.

mod helpers;

use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::circle::{CircleError, DecryptedIngest};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::set_epoch_anchor_write_fault_for_test;
use haven_core::nostr::mls::types::{
    FanoutMls, FanoutTargetStatus, GroupId, LocationMessageResult, ScreenedIngest,
};
use haven_core::nostr::mls::{ChangeNote, StorageConfig, StoreFault};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::FanoutClock as _;
use haven_core::relay::fanout::{
    drive_one, DriveMode, EvolutionStatus, FanoutSend, FanoutStatus, FanoutTargetOutcome,
    LocationSeal, ModeSource, Publishing, SendHeld, Taken, FANOUT_BOUND_MS, FOLD_BUDGET_MS,
    ROW_BUDGET_MS,
};
use haven_core::relay::live_sync::{EngineProcessor, EventBus};
use helpers::drive::{
    epoch, has_fix, leave_of, newest_commit_row, reads, records_of, roster, sealed_by, staged_ref,
    stored_fix, through, wait_out_the_engine, within, ManualClock, NarrowsWhenHeld, Recorder,
    HOUR_MS, SECOND_MS,
};
use helpers::{assert_no_needles, capture_haven_log, setup_circle, CircleFixture, CircleMember};

const ONE: &str = "wss://one.finishonly-canary5b9e.example.com";
const TWO: &str = "wss://two.finishonly-canary5b9e.example.com";
const CANARY: &str = "finishonly-canary5b9e";

const FULL: DriveMode = DriveMode::Full;
const FINISH_ONLY: DriveMode = DriveMode::FinishOnly;
/// Room for two rows: a finish-only call begins a row only inside a budget.
const ROOM_MS: u64 = 2 * ROW_BUDGET_MS;

fn split(fx: CircleFixture) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let mut members = fx.members;
    let admin = members.remove(0);
    (admin, members, fx.group)
}

fn db_of(member: &CircleMember) -> (std::path::PathBuf, storage_sqlite::SqlCipherKey) {
    (
        StorageConfig::new(member.dir.path()).database_path(),
        StorageConfig::test_sqlcipher_key().expect("test key"),
    )
}

async fn queued(member: &CircleMember, group: &GroupId) -> usize {
    member
        .session()
        .queued_intent_count_for_test(group)
        .await
        .expect("the queue is read")
}

/// A circle of three whose admin has just handed over to its last member: a
/// change that removes nobody, recorded for `relays`, its first call to each
/// answered with `first` in the full mode, and still awaiting them.
async fn a_hand_over_awaiting(
    relays: &[&str],
    first: Answer,
) -> (
    CircleMember,
    Vec<CircleMember>,
    GroupId,
    ScriptedFanout,
    u64,
) {
    let answered: Vec<(&str, Answer)> = relays.iter().map(|relay| (*relay, first)).collect();
    a_hand_over_answered(&answered).await
}

/// [`a_hand_over_awaiting`], with each relay's first answer its own.
async fn a_hand_over_answered(
    answered: &[(&str, Answer)],
) -> (
    CircleMember,
    Vec<CircleMember>,
    GroupId,
    ScriptedFanout,
    u64,
) {
    let relays: Vec<&str> = answered.iter().map(|(relay, _)| *relay).collect();
    let fx = setup_circle(3, &relays).await;
    let (admin, others, group) = split(fx);
    // Read before the change is staged: the engine reports the epoch a
    // staged commit leads to.
    let source = epoch(&admin, &group).await;
    let transport = ScriptedFanout::default();
    for (relay, first) in answered {
        transport.answer(relay, [*first]);
    }
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let staged = through(&transport, &outbox, &clock, &FULL)
        .admin_handoff(&admin.circle, &group, &others[1].keys.public_key())
        .await
        .expect("the hand-over is accepted");
    assert_eq!(staged.status, EvolutionStatus::Unresolved, "premise");
    transport.calls();
    (admin, others, group, transport, source)
}

// ── What a death around a confirm costs ──────────────────────────────────────

/// What a process death between a confirm's transaction and the engine's
/// replay costs, measured on the real engine. A peer's fix arrives while this
/// device's commit is pending, and the engine parks it unread — as it parks
/// every `kind:445` of the circle then, a commit or a proposal as much as a
/// fix. A relay then acknowledges the commit; the confirm's transaction
/// lands — the commit is applied and its record says so — and the process
/// dies before the engine has replayed what it had parked.
///
/// The parked fix is then STRANDED, not lost. The engine delivers it by
/// nothing of its own: not the next open, not the outputs the open hands
/// back, not a later event of the same peer, and not the very same event
/// delivered again — that redelivery is answered `Buffered`, never "seen".
/// It is delivered when this device next confirms a commit of its own in
/// that circle, because that is when the engine replays what it holds parked
/// (a rollback and a re-join are the other two:
/// `stranded_input_measured_e2e.rs`, with every other way a row is stranded).
/// A device that makes no commit never drains it. That is MDK's behaviour,
/// in every mode (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY) — measured
/// here on the engine opened with no circle store behind it, which is what
/// Haven opens less what it then does about such a row: it tells the circle
/// and hands the row back to the engine (`stranded_input_e2e.rs`).
///
/// If the first half fails because the fix IS delivered after the reopen,
/// MDK replays what it parked at hydrate; if the second fails, a stranded
/// row is not drained by a later confirm either. Either way the tracker row
/// and what Haven does about it change.
#[tokio::test]
async fn a_fix_parked_behind_a_pending_commit_is_stranded_by_a_kill_until_this_devices_next_confirm(
) {
    use helpers::stranded::{bare, fixes, parks, stage_relays};

    let (admin, others, group, transport, source) =
        a_hand_over_awaiting(&[ONE], Answer::Silent).await;
    let (db, key) = db_of(&admin);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);

    let parked = sealed_by(&others[0], &group, 48.25).await;
    let held = admin
        .circle
        .ingest_for_test(&parked)
        .await
        .expect("the ingest runs");
    assert!(held.is_empty(), "premise: the engine parks the fix unread");

    // The confirm's transaction lands; the write right after it fails, so
    // the engine never reaches its replay; and the process ends there.
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    transport.answer(ONE, [Answer::Accepted]);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
    assert!(resumed.errored, "premise: the confirm ended on an error");
    assert_eq!(
        records_of(&admin, &group).await[0].mls,
        FanoutMls::Confirmed,
        "premise: the transaction landed",
    );
    let engine = bare(admin);
    assert_eq!(
        engine.session.epoch(&group).await.expect("epoch"),
        source + 1,
        "premise: applied",
    );

    let handed_back_at_the_open = fixes(&engine.session.drain().await);
    let later = sealed_by(&others[0], &group, 49.5).await;
    let ScreenedIngest::Ingested(fresh) = engine
        .session
        .process_event_settled_for_test(&later)
        .await
        .expect("a later event is ingested")
    else {
        panic!("a genuine envelope passes the pre-auth screen");
    };
    assert!(
        has_fix(&fixes(&fresh.effects), &others[0], 49.5),
        "premise: a receive plane works"
    );
    assert!(
        !has_fix(&handed_back_at_the_open, &others[0], 48.25)
            && !has_fix(&fixes(&fresh.effects), &others[0], 48.25),
        "the fix parked behind the commit was delivered after the kill with no confirm \
         of this device's in between: MDK replays what it parked by itself — update \
         T-PARKED-REPLAY",
    );
    assert!(
        parks(&engine.session, &parked).await,
        "the engine no longer answers the redelivery of a stranded event `Buffered`: \
         update T-PARKED-REPLAY, and the rule in `relay::catchup::cursor_verdict`",
    );

    // A later commit of this device's own in that circle, confirmed: the
    // engine replays what it still holds parked.
    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, TWO]).await;
    let confirmed = engine
        .session
        .confirm_published(pending)
        .await
        .expect("a later commit of this device's own is confirmed");
    assert!(
        engine.session.epoch(&group).await.expect("epoch") == source + 2
            && has_fix(&fixes(&confirmed), &others[0], 48.25),
        "the stranded fix was not delivered by this device's next own confirm: nothing \
         drains a parked row a kill left behind — update T-PARKED-REPLAY",
    );
}

/// A confirm whose transaction landed and whose engine half did not — the
/// write after the merge failed — is finished by a finish-only call in the
/// same process, whichever mode's confirm it was. The commit is already
/// applied and on record, so nothing is decided; what the engine had parked
/// is replayed while the process still lives (a death first strands it: the
/// test above, and `stranded_input_e2e.rs` for what Haven then does). No
/// relay is called.
#[tokio::test]
async fn a_confirm_the_engine_stored_and_did_not_finish_is_finished_by_a_finish_only_call() {
    for confirming in [FULL, FINISH_ONLY] {
        let (admin, others, group, transport, source) =
            a_hand_over_awaiting(&[ONE], Answer::Silent).await;
        let (db, key) = db_of(&admin);
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(31 * SECOND_MS);
        let parked = sealed_by(&others[0], &group, 48.25).await;
        let held = admin
            .circle
            .ingest_for_test(&parked)
            .await
            .expect("the ingest runs");
        assert!(held.is_empty(), "premise: the engine parks the fix unread");
        set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
        transport.answer(ONE, [Answer::Accepted]);
        let resumed = within(&transport, &outbox, &clock, &confirming, ROOM_MS)
            .resume(&admin.circle)
            .await;
        set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
        assert!(
            resumed.errored && records_of(&admin, &group).await[0].mls == FanoutMls::Confirmed,
            "premise: the transaction landed and the confirm ended on an error",
        );
        assert!(
            staged_ref(&admin, &group).await.is_some(),
            "a confirm that ended on an error after its transaction was rolled back or \
             retried: the engine still holds what it has to finish",
        );
        transport.calls();

        let finished = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
            .resume(&admin.circle)
            .await;
        assert!(
            has_fix(&finished.replayed, &others[0], 48.25)
                && stored_fix(&admin, &group, &others[0], 48.25).await,
            "the fix parked behind the commit was not replayed by the finish-only call that \
             finished its confirm",
        );
        assert!(
            transport.calls().is_empty() && outbox.handed().is_empty(),
            "finishing a stored confirm called a relay or published something",
        );
        assert_eq!(epoch(&admin, &group).await, source + 1);
    }
}

/// A process that dies inside a finish-only call's confirm — the transaction
/// landed, the engine's replay never ran — loses nothing silently. The next
/// process finds the commit applied and its record saying so, and its circle
/// told that a location waits unread; the next finish-only call for the
/// circle hands that fix back ahead of the event it was called with, and the
/// note ends. No relay is called and nothing is published on the way.
#[tokio::test]
async fn a_death_inside_a_finish_only_confirm_leaves_what_was_parked_told_and_handed_back() {
    let (admin, others, group, transport, source) =
        a_hand_over_awaiting(&[ONE], Answer::Silent).await;
    let (db, key) = db_of(&admin);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    let parked = sealed_by(&others[0], &group, 48.25).await;
    let held = admin
        .circle
        .ingest_for_test(&parked)
        .await
        .expect("the ingest runs");
    assert!(held.is_empty(), "premise: the engine parks the fix unread");
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    transport.answer(ONE, [Answer::Accepted]);
    let dying = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
    assert!(
        dying.errored && dying.replayed.is_empty(),
        "premise: the finish-only confirm ended on an error before the replay",
    );
    transport.calls();

    let admin = admin.reopen();
    assert!(
        epoch(&admin, &group).await == source + 1
            && records_of(&admin, &group).await[0].mls == FanoutMls::Confirmed,
        "a confirm cut after its transaction did not land whole: the commit is not applied, \
         or its record does not say so",
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::UnreadLocation],
        "the circle was not told that a location waits unread behind the cut confirm",
    );

    // Another member's: the store keeps one fix a member, the freshest by
    // the second, so which of two fixes of ONE member it holds would turn on
    // where a second's boundary fell between their seals.
    let fresh = sealed_by(&others[1], &group, 48.5).await;
    let polled = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .ingest_for_poll(&admin.circle, &fresh)
        .await
        .expect("the next finish-only call runs");
    assert!(
        polled.replayed.len() == 2
            && has_fix(&polled.replayed[..1], &others[0], 48.25)
            && has_fix(&polled.replayed[1..], &others[1], 48.5),
        "the fix parked behind the cut confirm was not handed back ahead of the event the \
         next finish-only call was made with",
    );
    assert!(
        admin.session().peek_change_notes(&group).is_empty()
            && stored_fix(&admin, &group, &others[0], 48.25).await
            && stored_fix(&admin, &group, &others[1], 48.5).await,
        "the note still stands after the hand-back, or a fix the call handed back or took \
         is not stored",
    );
    assert!(
        transport.calls().is_empty() && outbox.handed().is_empty(),
        "telling of, or handing back, what a cut confirm left called a relay or published \
         something",
    );
}

// ── What a finish-only call does ───────────────────────────────────────────────

/// The same bytes go to a relay that is due, its acknowledgement is stored,
/// and — the call having a whole fold's budget left — the commit is
/// confirmed in that call: applied, its record saying so, nothing handed to
/// any other publisher. What is left of the record is a full drive's: a
/// later finish-only call does nothing with it.
#[tokio::test]
async fn a_finish_only_call_confirms_a_commit_its_own_send_was_acknowledged_for() {
    let (admin, _others, group, transport, before) =
        a_hand_over_awaiting(&[ONE], Answer::Silent).await;
    let frozen = records_of(&admin, &group).await.remove(0);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(31 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);

    let resumed = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    let calls = transport.calls();
    assert_eq!(calls.len(), 1, "the due relay was not called once");
    assert!(calls[0].event_id == frozen.event_id && calls[0].payload == frozen.payload);
    let record = records_of(&admin, &group).await.remove(0);
    assert_eq!(
        (
            record.mls,
            record.statuses.as_slice(),
            staged_ref(&admin, &group).await.is_some(),
            epoch(&admin, &group).await,
            resumed.errored,
        ),
        (
            FanoutMls::Confirmed,
            &[FanoutTargetStatus::Accepted][..],
            false,
            before + 1,
            false,
        ),
        "a finish-only call with a fold's budget left did not confirm the commit its relay \
         had just acknowledged",
    );
    assert!(
        outbox.handed().is_empty(),
        "a finish-only confirm published something that has no record",
    );

    let again = standing(&admin, &group).await;
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().is_empty() && standing(&admin, &group).await == again,
        "a finish-only call went on with an applied commit's record",
    );
}

/// An acknowledgement that came back with less than a fold's budget left is
/// stored and nothing is confirmed: the call asks to be driven again at
/// once, and a send meanwhile is told what it waits for. The stored record
/// is then all a confirm needs — in the same process or after its death, by
/// the next finish-only call that has a fold's budget, one millisecond less
/// being too little — and no relay is called for it again.
#[tokio::test]
async fn a_stored_acknowledgement_is_confirmed_by_a_finish_only_call_with_a_folds_budget_left() {
    for dies in [false, true] {
        let (mut admin, _others, group, transport, before) =
            a_hand_over_awaiting(&[ONE], Answer::Silent).await;
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(31 * SECOND_MS);
        transport.answer(ONE, [Answer::Accepted]);
        transport.park();
        // The relay answers when the wake has one millisecond less than a
        // fold left.
        let driver = within(&transport, &outbox, &clock, &FINISH_ONLY, ROW_BUDGET_MS);
        let (resumed, ()) = tokio::join!(driver.resume(&admin.circle), async {
            transport.parked().await;
            clock.set(31 * SECOND_MS + ROW_BUDGET_MS - FOLD_BUDGET_MS + 1);
            transport.unpark();
        });
        assert_eq!(transport.calls().len(), 1, "premise: the relay was called");
        let record = records_of(&admin, &group).await.remove(0);
        assert_eq!(
            (
                record.mls,
                record.statuses.as_slice(),
                staged_ref(&admin, &group).await.is_some(),
                resumed.retry_after_ms,
            ),
            (
                FanoutMls::Pending,
                &[FanoutTargetStatus::Accepted][..],
                true,
                Some(0),
            ),
            "a finish-only call began a confirm it had no fold's budget for, did not store \
             the relay's answer, or did not ask to be driven again",
        );
        // A send meanwhile is told what it waits for: no longer a relay.
        let held = within(
            &transport,
            &outbox,
            &clock,
            &FINISH_ONLY,
            FOLD_BUDGET_MS - 1,
        )
        .seal_location(&admin.circle, &group, &LocationMessage::new(51.5, -0.12))
        .await
        .expect("the call runs");
        assert!(
            matches!(held.seal, LocationSeal::Deferred(SendHeld::Acknowledged)),
            "a send held by an acknowledged commit was told it awaits its relays",
        );
        assert!(
            staged_ref(&admin, &group).await.is_some(),
            "a finish-only call one millisecond short of a fold's budget confirmed",
        );
        if dies {
            admin = admin.reopen();
        }

        let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, FOLD_BUDGET_MS)
            .resume(&admin.circle)
            .await;
        assert!(
            transport.calls().is_empty() && outbox.handed().is_empty(),
            "confirming a stored acknowledgement called a relay again, or published",
        );
        assert_eq!(
            (
                epoch(&admin, &group).await,
                staged_ref(&admin, &group).await.is_some(),
                records_of(&admin, &group).await[0].mls,
            ),
            (before + 1, false, FanoutMls::Confirmed),
            "a stored acknowledgement was not confirmed by the next finish-only call with a \
             fold's budget left",
        );
        // And the send it held goes out.
        let sent = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
            .seal_location(&admin.circle, &group, &LocationMessage::new(51.5, -0.12))
            .await
            .expect("the call runs");
        assert!(
            matches!(sent.seal, LocationSeal::Sealed { .. }),
            "a location was still held after its circle's commit was confirmed",
        );
    }
}

/// A change of the circle's relays is a full drive's to confirm, whatever
/// its record holds: the session's subscriptions follow a circle's relays
/// only by what the app does in a full plane, so a finish-only call stores
/// the acknowledgement and leaves the circle's row as it is. The full drive
/// that follows confirms without calling a relay, and the row follows.
#[tokio::test]
async fn a_finish_only_call_leaves_an_acknowledged_change_of_relays_to_a_full_drive() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = epoch(&admin, &group).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    transport.answer(TWO, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let relays = [ONE.to_string(), TWO.to_string()];
    let staged = through(&transport, &outbox, &clock, &FULL)
        .update_relays(&admin.circle, &group, &relays)
        .await
        .expect("the change is accepted");
    assert_eq!(staged.status, EvolutionStatus::Unresolved, "premise");
    transport.calls();
    let row = |member: &CircleMember| {
        let circle = std::sync::Arc::clone(&member.circle);
        let group = group.clone();
        async move {
            circle
                .get_circle(&group)
                .await
                .expect("the circle store is read")
                .expect("the circle exists")
                .circle
                .relays
        }
    };

    clock.set(31 * SECOND_MS);
    for relay in [ONE, TWO] {
        transport.answer(relay, [Answer::Accepted]);
    }
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        !transport.calls().is_empty(),
        "premise: a relay that was due was called",
    );
    let record = records_of(&admin, &group).await.remove(0);
    assert!(
        record.mls == FanoutMls::Pending
            && record.statuses.contains(&FanoutTargetStatus::Accepted)
            && staged_ref(&admin, &group).await.is_some()
            && row(&admin).await == [ONE.to_string()],
        "a finish-only call confirmed a change of the circle's relays",
    );

    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && epoch(&admin, &group).await == before + 1
            && row(&admin).await == relays,
        "the full drive did not confirm the change, or the circle's row did not follow",
    );
}

/// The one change of relays a finish-only call does finish is one already
/// applied: a confirm whose transaction landed and that the engine did not
/// complete. Nothing is decided by finishing it, and the circle's row
/// follows the engine in that call.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_change_of_relays_already_applied_is_finished_and_the_circles_row_follows() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let (db, key) = db_of(&admin);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let relays = [ONE.to_string(), TWO.to_string()];
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    let _ = through(&transport, &outbox, &clock, &FULL)
        .update_relays(&admin.circle, &group, &relays)
        .await;
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
    assert!(
        records_of(&admin, &group).await[0].mls == FanoutMls::Confirmed
            && staged_ref(&admin, &group).await.is_some(),
        "premise: the transaction landed and the engine did not finish",
    );
    transport.calls();

    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    let stored = admin
        .circle
        .get_circle(&group)
        .await
        .expect("the circle store is read")
        .expect("the circle exists")
        .circle
        .relays;
    assert!(
        staged_ref(&admin, &group).await.is_none() && stored == relays,
        "a change of relays already applied was not finished, or the circle's row did not \
         follow",
    );
    assert!(transport.calls().is_empty() && outbox.handed().is_empty());

    // Finished from the background, the circle is sealed for at its new
    // relays while this device still listens on the old ones: it could miss
    // a removal there. So nothing is sealed for it except by a claimed
    // foreground, said typed, until a full drive has completed in one.
    let location = LocationMessage::new(51.5, -0.12);
    let held = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    assert!(
        matches!(
            held.seal,
            LocationSeal::Deferred(SendHeld::AwaitsForeground)
        ) && admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::AwaitsForeground),
        "a location was sealed from the background for a circle whose change of relays was \
         finished there, or the hold was not said typed",
    );
    admin
        .session()
        .acknowledge_change_notice(&group, &admin.session().change_notice(&group));
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::AwaitsForeground),
        "the hold was acknowledged away: it says what is, and ends when a full drive runs",
    );

    // A full drive in a process nobody has claimed the foreground for ends
    // nothing: what the circle waits for is a foreground.
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::AwaitsForeground),
        "a full drive that was nobody's foreground ended the hold",
    );
    // A send in the full mode, as a caller that says the app is in front of
    // its user makes one.
    let seal_full = || async {
        through(&transport, &outbox, &clock, &FULL)
            .seal_location(&admin.circle, &group, &location)
            .await
            .expect("the send is answered")
            .seal
    };
    // A process with no live plane says nothing about whether it is in front
    // of its user, and on Android the one that shares in the background is
    // such a process: its own send is deferred too.
    assert!(
        matches!(
            seal_full().await,
            LocationSeal::Deferred(SendHeld::AwaitsForeground)
        ),
        "a process with no live plane sealed for a circle whose change of relays was \
         finished away from the foreground",
    );
    // A session that has only been started reads the hold as a burst does:
    // a background wake that cold-launched the process is one. Its own send
    // in the full mode is deferred.
    let plane = EngineProcessor::new(std::sync::Arc::clone(&admin.circle), EventBus::new());
    plane.for_test().note_launched();
    assert!(
        matches!(
            seal_full().await,
            LocationSeal::Deferred(SendHeld::AwaitsForeground)
        ),
        "a session only started sealed for a circle whose change of relays was finished \
         away from the foreground",
    );

    // Claimed for the foreground, its own sends are made — and its full
    // drive, once it has run to its end, ends the hold.
    assert!(plane.for_test().prove_foreground(), "the claim is taken");
    assert!(
        matches!(seal_full().await, LocationSeal::Sealed { .. }),
        "a claimed foreground's own send was held",
    );
    // A send that foreground decided on and that is made behind a wait in
    // which it ended — for the engine, then for a hand-back — is no longer
    // a claimed foreground's: it reads the hold, and seals nothing.
    let ended = NarrowsWhenHeld::after(&admin, 1);
    let late = through(&transport, &outbox, &clock, &ended)
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    assert!(
        ended.narrowed()
            && matches!(
                late.seal,
                LocationSeal::Deferred(SendHeld::AwaitsForeground)
            ),
        "a send made after its foreground had ended in the hand-back was sealed for a circle \
         left waiting for one, or the hold was not said typed",
    );
    // A pause that lands while that drive waits for the engine ends
    // nothing: the drive asks again once it has it.
    let paused = NarrowsWhenHeld::after(&admin, 0);
    let _ = through(&transport, &outbox, &clock, &paused)
        .resume(&admin.circle)
        .await;
    assert!(
        paused.narrowed()
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::AwaitsForeground),
        "a full drive whose foreground ended while it waited for the engine ended the hold",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    plane.for_test().leave_foreground();
    let sent = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    assert!(
        matches!(sent.seal, LocationSeal::Sealed { .. })
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::AwaitsForeground),
        "the hold did not end with a full drive completed in a claimed foreground",
    );
    // Ended, it is ended for a process with no live plane as well.
    drop(plane);
    assert!(
        admin
            .circle
            .seal_location_for_test(&group, &location)
            .await
            .is_ok(),
        "a process with no live plane was still held after the hold had ended",
    );
}

/// A change of relays is not finished from the background while its circle
/// cannot be marked as waiting for the foreground. That mark is what holds
/// the circle's background sends once the change is applied; finished
/// without it, the device would seal for the new relays, unattended, while
/// it still listens on the old ones. The confirm stays as it is stored, and
/// is finished by the first call that can write the mark.
#[tokio::test]
async fn a_change_of_relays_is_not_finished_narrow_while_its_circle_cannot_be_marked() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let (db, key) = db_of(&admin);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let relays = [ONE.to_string(), TWO.to_string()];
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    let _ = through(&transport, &outbox, &clock, &FULL)
        .update_relays(&admin.circle, &group, &relays)
        .await;
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
    assert!(
        records_of(&admin, &group).await[0].mls == FanoutMls::Confirmed
            && staged_ref(&admin, &group).await.is_some(),
        "premise: the transaction landed and the engine did not finish",
    );
    transport.calls();
    let marked = || {
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::AwaitsForeground)
    };
    let row = |member: &CircleMember| {
        let circle = std::sync::Arc::clone(&member.circle);
        let group = group.clone();
        async move {
            circle
                .get_circle(&group)
                .await
                .expect("the circle store is read")
                .expect("the circle exists")
                .circle
                .relays
        }
    };

    // The circle store refuses every write of a circle's notes.
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = rusqlite::Connection::open(
        admin
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens");
    store
        .execute_batch(
            "CREATE TRIGGER mark_fault BEFORE INSERT ON commit_notes
             BEGIN SELECT RAISE(FAIL, 'fault'); END;
             CREATE TRIGGER mark_fault_update BEFORE UPDATE ON commit_notes
             BEGIN SELECT RAISE(FAIL, 'fault'); END;",
        )
        .expect("the fault is armed");
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && row(&admin).await == [ONE.to_string()]
            && !marked(),
        "a change of relays was finished from the background though its circle could not \
         be marked as waiting for the foreground: nothing holds its background sends",
    );

    store
        .execute_batch("DROP TRIGGER mark_fault; DROP TRIGGER mark_fault_update;")
        .expect("the fault is lifted");
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_none() && row(&admin).await == relays && marked(),
        "once the mark could be written the change was not finished, or was finished \
         unmarked",
    );
}

/// What a confirm's replay leaves stranded is handed back in the same call,
/// however much of it there is: the replay ended on an error at the first of
/// twenty-one parked fixes, and every one behind it is in what the call
/// replayed, in the order it arrived, with its circle told nothing — in the
/// full mode, whose fold hands a circle's stranded input back whole, and in
/// the mode that only finishes, whose fold hands back sixteen and whose
/// drive then serves the circle once more while the wake has a fold's budget
/// left.
#[tokio::test]
async fn what_a_confirms_replay_left_stranded_is_handed_back_in_the_same_call() {
    use haven_core::nostr::mls::storage::set_stored_message_write_fault_naming_for_test;
    const BEHIND: u32 = 20;
    // No one of these reads as part of another.
    let latitude_of = |index: u32| f64::from(index) + 10.125;
    for mode in [FINISH_ONLY, FULL] {
        let (admin, others, group, transport, source) =
            a_hand_over_awaiting(&[ONE], Answer::Silent).await;
        let (db, key) = db_of(&admin);
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(31 * SECOND_MS);
        let struck = sealed_by(&others[0], &group, 48.25).await;
        assert!(helpers::stranded::parks(admin.session(), &struck).await);
        for index in 0..BEHIND {
            let fix = sealed_by(&others[1], &group, latitude_of(index)).await;
            assert!(
                helpers::stranded::parks(admin.session(), &fix).await,
                "premise: the engine parks what arrives behind its pending commit unread",
            );
        }
        set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), true)
            .expect("arm");
        transport.answer(ONE, [Answer::Accepted]);
        let resumed = within(&transport, &outbox, &clock, &mode, ROOM_MS)
            .resume(&admin.circle)
            .await;
        set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), false)
            .expect("disarm");
        assert!(
            resumed.errored && epoch(&admin, &group).await == source + 1,
            "premise: the commit was applied and its replay ended on an error",
        );
        let behind: Vec<_> = resumed
            .replayed
            .iter()
            .filter(|result| {
                matches!(
                    result,
                    LocationMessageResult::Location { sender_pubkey, .. }
                        if *sender_pubkey == others[1].pubkey_hex()
                )
            })
            .collect();
        assert!(
            behind.len() == BEHIND as usize
                && (0..BEHIND).zip(&behind).all(|(index, result)| {
                    has_fix(
                        std::slice::from_ref(*result),
                        &others[1],
                        latitude_of(index),
                    )
                }),
            "what a confirm's replay left stranded was not all handed back in that call, in \
             the order it arrived",
        );
        assert!(
            admin
                .session()
                .peek_change_notes(&group)
                .iter()
                .all(|note| !matches!(note, ChangeNote::UnreadLocation | ChangeNote::UnreadChange)),
            "a circle whose stranded input was all handed back is still told it holds some",
        );
    }
}

/// Every relay proves it refused the commit, and none was ever possibly
/// exposed: a full drive rolls it back. A pass that had narrowed by the time
/// its relay answered stores the refusal and rolls nothing back, and a
/// finish-only call then leaves the record exactly as it is stored — it does
/// not so much as take up a record no relay may hold — for the full drive
/// that follows.
#[tokio::test]
async fn a_finish_only_call_never_rolls_back_whatever_the_relays_prove() {
    let (admin, _others, group, transport, _) =
        a_hand_over_awaiting(&[ONE], Answer::Unreachable).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(6 * SECOND_MS);
    transport.answer(ONE, [Answer::Refused]);
    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);

    // Full where its attempt is marked, finish-only from the next read on:
    // the foreground ended while the relay was answering.
    let mut reads = 0;
    loop {
        let mode = NarrowsAfter::reads(reads);
        let _ = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &mode)
            .await
            .expect("the drive returns");
        if !transport.calls().is_empty() {
            break;
        }
        reads += 1;
        assert!(
            reads < 16,
            "premise: the relay is called by a pass that is full"
        );
    }
    let stored = standing(&admin, &group).await;
    assert_eq!(
        (stored[0].2, stored[0].3.as_slice()),
        (FanoutMls::Pending, &[FanoutTargetStatus::Failed][..]),
        "premise: the refusal is stored and nothing was decided",
    );

    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && admin.session().peek_change_notes(&group).is_empty()
            && standing(&admin, &group).await == stored
            && transport.calls().is_empty(),
        "a finish-only call rolled a commit back, or touched a record no relay may hold",
    );

    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(staged_ref(&admin, &group).await.is_none());
    assert_eq!(
        admin.session().peek_change_notes(&group),
        vec![ChangeNote::ChangeUndone],
        "premise: a full drive undoes it, and says so",
    );
}

/// A change that removes nobody and that no relay could be reached for in a
/// day is undone by a full drive. A finish-only call past that day undoes
/// nothing, and calls nothing either: no relay may hold the commit, and its
/// next transmission would be the first that leaves this device.
#[tokio::test]
async fn a_finish_only_call_never_applies_the_bound() {
    let (admin, _others, group, transport, _) =
        a_hand_over_awaiting(&[ONE], Answer::Unreachable).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(FANOUT_BOUND_MS + HOUR_MS);
    let stored = standing(&admin, &group).await;

    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && standing(&admin, &group).await == stored
            && transport.calls().is_empty(),
        "a finish-only call undid a commit at its bound, or sent one no relay may hold",
    );

    clock.set(FANOUT_BOUND_MS + 4 * HOUR_MS);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_none(),
        "premise: a full drive past the bound undoes it",
    );
}

/// A finish-only call re-sends only what a relay may already hold. A record
/// whose every attempt found its relay unreachable left the device nowhere:
/// its next transmission is a first one, and a full drive's. And of a record
/// one relay may hold, a relay that was never attempted is not attempted
/// from here either: the call goes to the relay that was sent it before, and
/// to no other. A first transmission the operating system cut would leave a
/// commit nobody held stored as possibly exposed for good.
#[tokio::test]
async fn a_finish_only_call_makes_no_first_transmission_to_any_relay() {
    // Attempted, and unreachable: nothing left the device.
    let (admin, _others, group, transport, _) =
        a_hand_over_awaiting(&[ONE], Answer::Unreachable).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(HOUR_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let stored = standing(&admin, &group).await;
    assert_eq!(
        (stored[0].3.as_slice(), stored[0].4.as_slice()),
        (&[FanoutTargetStatus::RetryableUnavailable][..], &[1][..]),
        "premise: one attempt, which found the relay unreachable",
    );
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().is_empty() && standing(&admin, &group).await == stored,
        "a finish-only call made the first transmission of a commit no relay may hold",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert_eq!(transport.calls().len(), 1, "control: a full drive sends it");

    // One relay may hold it; the other was never attempted.
    let (admin, _others, group, transport, _) =
        a_hand_over_answered(&[(ONE, Answer::Silent), (TWO, Answer::Busy)]).await;
    let clock = ManualClock::at(HOUR_MS);
    transport.answer(ONE, [Answer::Silent]);
    transport.answer(TWO, [Answer::Accepted]);
    assert_eq!(
        standing(&admin, &group).await[0].3,
        [
            FanoutTargetStatus::PossiblyExposed,
            FanoutTargetStatus::NotAttempted
        ],
        "premise: one relay may hold the commit, the other was never attempted",
    );
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    let calls = transport.calls();
    assert!(
        calls.len() == 1
            && calls[0].target == ONE
            && standing(&admin, &group).await[0].3[1] == FanoutTargetStatus::NotAttempted,
        "a finish-only call gave a relay its first attempt, or did not send again to the \
         relay that may hold the commit",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().iter().any(|call| call.target == TWO),
        "control: a full drive gives the other relay its attempt",
    );
}

/// A pass decides, and then waits for the engine — which a whole hand-back
/// of stranded input can be holding. The lifecycle it decided under can end
/// in that wait, so each act that may not outlive it reads the mode again
/// with the engine held, and is not made when the foreground has ended: a
/// rollback, the bound, a confirm, a Welcome's hand-over. The record is then
/// exactly as it was stored, and the full drive that follows does what was
/// left.
#[tokio::test]
async fn an_act_decided_before_the_foreground_ended_is_not_made_once_the_engine_is_had() {
    let outbox = Recorder::acking(true);

    // A rollback: the relay proves its refusal to a pass that is full, and
    // the foreground ends while that pass waits for the engine to undo it.
    let (admin, _others, group, transport, _) =
        a_hand_over_awaiting(&[ONE], Answer::Unreachable).await;
    let clock = ManualClock::at(6 * SECOND_MS);
    transport.answer(ONE, [Answer::Refused]);
    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);
    let mode = NarrowsWhenHeld::after(&admin, 1);
    let _ = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &mode).await;
    let stored = standing(&admin, &group).await;
    assert!(
        transport.calls().len() == 1
            && stored[0].2 == FanoutMls::Pending
            && stored[0].3 == [FanoutTargetStatus::Failed]
            && staged_ref(&admin, &group).await.is_some()
            && admin.session().peek_change_notes(&group).is_empty(),
        "a commit was rolled back after the foreground had ended, by a pass that decided \
         before it did",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(staged_ref(&admin, &group).await.is_none(), "control");

    // The bound, likewise.
    let (admin, _others, group, transport, _) =
        a_hand_over_awaiting(&[ONE], Answer::Unreachable).await;
    let clock = ManualClock::at(FANOUT_BOUND_MS + HOUR_MS);
    transport.answer(ONE, [Answer::Unreachable]);
    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);
    let mode = NarrowsWhenHeld::after(&admin, 1);
    let _ = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &mode).await;
    let stored = standing(&admin, &group).await;
    assert!(
        transport.calls().len() == 1
            && stored[0].2 == FanoutMls::Pending
            && stored[0].3 == [FanoutTargetStatus::RetryableUnavailable]
            && staged_ref(&admin, &group).await.is_some(),
        "the bound was applied after the foreground had ended",
    );
    clock.set(FANOUT_BOUND_MS + 4 * HOUR_MS);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(staged_ref(&admin, &group).await.is_none(), "control");

    // A confirm: the acknowledgement is stored, and is the next pass's.
    let (admin, _others, group, transport, source) =
        a_hand_over_awaiting(&[ONE], Answer::Silent).await;
    let clock = ManualClock::at(31 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);
    let mode = NarrowsWhenHeld::after(&admin, 1);
    let _ = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &mode).await;
    let stored = standing(&admin, &group).await;
    assert!(
        transport.calls().len() == 1
            && stored[0].2 == FanoutMls::Pending
            && stored[0].3 == [FanoutTargetStatus::Accepted]
            && staged_ref(&admin, &group).await.is_some(),
        "a commit was confirmed after the foreground had ended, by a pass that decided \
         before it did",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        epoch(&admin, &group).await == source + 1 && transport.calls().is_empty(),
        "control: the next full drive confirms the stored acknowledgement, with no relay \
         called",
    );
}

/// The same for a Welcome: an invite's commit is applied, and the foreground
/// ends while the pass that would hand its Welcome over waits for the
/// engine. Nothing is handed to the publisher; the Welcome stays on its
/// record, and the next full drive delivers it.
#[tokio::test]
async fn a_welcome_is_not_handed_over_once_the_engine_is_had_after_the_foreground_ended() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let joiner = CircleMember::new();
    let inbox = vec!["wss://inbox.finishonly-canary5b9e.example.com".to_string()];
    let invited = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            joiner.session(),
            &joiner.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox.clone(),
        nip65_relays: Vec::new(),
    };
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .add_members(&admin.circle, &group, &[invited])
        .await
        .expect("the invite is accepted");
    clock.set(31 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_none() && outbox.handed().is_empty(),
        "premise: the invite is applied and its Welcome is still on its record",
    );
    transport.calls();

    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);
    let mode = NarrowsWhenHeld::after(&admin, 0);
    let _ = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &mode)
        .await
        .expect("the drive runs");
    assert!(
        outbox.handed().is_empty()
            && admin
                .session()
                .fanout_probe_for_test(&id)
                .await
                .expect("the store is read")
                .is_some_and(|row| row.held_welcomes == 1),
        "a Welcome was handed over after the foreground had ended",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        outbox
            .handed()
            .iter()
            .any(|(event, relays)| event.kind.as_u16() == 1059 && relays == &inbox),
        "the Welcome a narrowed pass left on its record was not delivered by the next full \
         drive",
    );
}

/// A record no relay has been sent is silent in this mode: its first send is
/// a full drive's. And a call with no known budget, or with less than a whole
/// row of it left, begins nothing.
#[tokio::test]
async fn a_finish_only_call_makes_no_first_send_and_begins_nothing_without_a_rows_budget() {
    // Never sent: the relay could not be had when the change was made.
    let (admin, _others, group, transport, _) = a_hand_over_awaiting(&[ONE], Answer::Busy).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(HOUR_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let unsent = records_of(&admin, &group).await.remove(0);
    assert_eq!(
        unsent.statuses,
        [FanoutTargetStatus::NotAttempted],
        "premise"
    );
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().is_empty() && records_of(&admin, &group).await[0].attempts == [0],
        "a finish-only call made a record's first send",
    );

    // Sent before, and due: begun only inside a budget with a row left.
    let (admin, _others, group, transport, _) = a_hand_over_awaiting(&[ONE], Answer::Silent).await;
    let clock = ManualClock::at(31 * SECOND_MS);
    let _ = through(&transport, &outbox, &clock, &FINISH_ONLY)
        .resume(&admin.circle)
        .await;
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROW_BUDGET_MS - 1)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().is_empty() && records_of(&admin, &group).await[0].attempts == [1],
        "a finish-only call began a row it had no whole budget for",
    );
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROW_BUDGET_MS)
        .resume(&admin.circle)
        .await;
    assert_eq!(transport.calls().len(), 1);
}

/// A mode that reads full for its first `left` reads and finish-only from then
/// on, for good: a foreground that ends at a chosen point of a call.
struct NarrowsAfter(AtomicU64);

impl NarrowsAfter {
    const fn reads(left: u64) -> Self {
        Self(AtomicU64::new(left))
    }

    fn narrow(&self) {
        self.0.store(0, Ordering::SeqCst);
    }
}

impl ModeSource for NarrowsAfter {
    fn mode(&self) -> DriveMode {
        let full = self
            .0
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| {
                left.checked_sub(1)
            })
            .is_ok();
        if full {
            DriveMode::Full
        } else {
            DriveMode::FinishOnly
        }
    }
}

/// A transport whose relays are had only when the test lets them go.
struct HeldAtTheTake<'a> {
    inner: &'a ScriptedFanout,
    waiting: tokio::sync::Notify,
    free: tokio::sync::Notify,
}

#[async_trait::async_trait]
impl FanoutSend for HeldAtTheTake<'_> {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.waiting.notify_one();
        self.free.notified().await;
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &haven_core::nostr::mls::types::TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
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

/// What a record is, for "nothing touched it".
async fn standing(
    member: &CircleMember,
    group: &GroupId,
) -> Vec<(
    nostr::EventId,
    Vec<u8>,
    FanoutMls,
    Vec<FanoutTargetStatus>,
    Vec<u32>,
)> {
    records_of(member, group)
        .await
        .into_iter()
        .map(|record| {
            (
                record.event_id,
                record.payload,
                record.mls,
                record.statuses,
                record.attempts,
            )
        })
        .collect()
}

/// A drive that began full and is waiting for a relay when the foreground
/// ends makes no first send with the relay it then gets: nothing is marked
/// as begun, nothing is called, the record is byte for byte what it was, and
/// the relay is free for the next drive. A first send the operating system
/// cut would leave a commit nobody may hold stored as possibly exposed for
/// good.
#[tokio::test]
async fn a_relay_had_after_the_foreground_ended_is_given_back_and_no_first_send_is_made() {
    let (admin, _others, group, scripted, _) = a_hand_over_awaiting(&[ONE], Answer::Busy).await;
    scripted.answer(ONE, [Answer::Accepted]);
    let before = standing(&admin, &group).await;
    assert_eq!(
        before[0].3,
        [FanoutTargetStatus::NotAttempted],
        "premise: never sent"
    );
    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);
    let clock = ManualClock::at(HOUR_MS);
    let transport = HeldAtTheTake {
        inner: &scripted,
        waiting: tokio::sync::Notify::new(),
        free: tokio::sync::Notify::new(),
    };
    let mode = NarrowsAfter::reads(u64::MAX);
    {
        let drive = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &mode);
        tokio::pin!(drive);
        tokio::select! {
            biased;
            _ = &mut drive => panic!("the drive ended before it had its relay"),
            () = transport.waiting.notified() => {}
        }
        mode.narrow();
        transport.free.notify_one();
        let out = drive.await.expect("the drive returns");
        assert_eq!(out.status, FanoutStatus::Unresolved);
    }
    assert!(
        scripted.calls().is_empty(),
        "a first send was made after the foreground ended",
    );
    assert_eq!(
        standing(&admin, &group).await,
        before,
        "an attempt was stored for a record a narrowed pass may not send first",
    );

    // The relay was given back: the next full drive has it at once.
    transport.free.notify_one();
    let out = drive_one(&admin.circle, &transport, clock.as_ref(), &id, &FULL)
        .await
        .expect("the drive returns");
    assert_eq!(
        (out.status, scripted.calls().len()),
        (FanoutStatus::Confirmed, 1)
    );
}

/// The same promise at each point a drive reads its mode before a record's
/// first call. It reads four times before it marks the attempt — taking the
/// record up, before its first settlement, once it has its relays, and in
/// the very hold that marks — and a foreground that ends before any of them
/// leaves the record untouched and uncalled. One that ends after the mark
/// ends a call that was already begun, which is made.
#[tokio::test]
async fn a_first_send_is_begun_only_if_the_mode_is_still_full_where_its_attempt_is_marked() {
    let (admin, _others, group, scripted, _) = a_hand_over_awaiting(&[ONE], Answer::Busy).await;
    scripted.answer(ONE, [Answer::Silent]);
    let before = standing(&admin, &group).await;
    let id = admin
        .session()
        .fanout_ids_for_test(&group)
        .await
        .expect("the store is read")
        .remove(0);
    let clock = ManualClock::at(HOUR_MS);
    for reads in 0..4 {
        let mode = NarrowsAfter::reads(reads);
        let _ = drive_one(&admin.circle, &scripted, clock.as_ref(), &id, &mode)
            .await
            .expect("the drive returns");
        assert!(
            scripted.calls().is_empty() && standing(&admin, &group).await == before,
            "a first send was begun by a pass that narrowed after {reads} read(s) of its mode",
        );
    }
    let mode = NarrowsAfter::reads(4);
    let _ = drive_one(&admin.circle, &scripted, clock.as_ref(), &id, &mode)
        .await
        .expect("the drive returns");
    assert_eq!(
        (
            scripted.calls().len(),
            records_of(&admin, &group).await[0].attempts.as_slice()
        ),
        (1, &[1][..]),
        "control: a pass still full where its attempt is marked makes the call",
    );
}

/// A Welcome whose send was not begun after its route was taken — the
/// foreground ended between the driver's read of its mode and the
/// publisher's own — keeps its route: wherever in a pass the foreground
/// ends, a later full drive still delivers the Welcome. Without the route
/// put back it would be spent with nothing sent, and its invitee locked out
/// until invited again.
#[tokio::test]
async fn a_welcome_whose_send_was_not_begun_keeps_its_route_wherever_the_foreground_ends() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let joiner = CircleMember::new();
    let inbox = vec!["wss://inbox.finishonly-canary5b9e.example.com".to_string()];
    let invited = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            joiner.session(),
            &joiner.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox.clone(),
        nip65_relays: Vec::new(),
    };
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let invite = within(&transport, &outbox, &clock, &FULL, ROW_BUDGET_MS)
        .add_members(&admin.circle, &group, &[invited])
        .await
        .expect("the invite is accepted");
    assert_eq!(
        (invite.status, invite.welcomes_sent, outbox.handed().len()),
        (EvolutionStatus::Confirmed, 0, 0),
        "premise: applied, and its Welcome not yet handed over",
    );
    clock.set(HOUR_MS);

    let delivered = || {
        outbox
            .handed()
            .iter()
            .any(|(event, relays)| event.kind.as_u16() == 1059 && relays == &inbox)
    };
    let mut narrowed_passes = 0_u64;
    while !delivered() {
        assert!(
            narrowed_passes < 64,
            "the Welcome's route was spent by a pass that sent nothing: no later drive \
             delivers it",
        );
        let mode = NarrowsAfter::reads(narrowed_passes);
        let pass = Publishing {
            fanout: &transport,
            publisher: &outbox,
            clock: clock.as_ref(),
            deadline_ms: None,
            mode: &mode,
        };
        let _ = pass.resume(&admin.circle).await;
        narrowed_passes += 1;
    }
    assert!(
        narrowed_passes > 1,
        "premise: at least one pass narrowed before the Welcome was handed over",
    );
}

/// Nothing without a record is published in this mode: not a Welcome an
/// applied invite still owes, and not a proposal no record could be written
/// for. A full drive sends both.
#[tokio::test]
async fn a_finish_only_call_delivers_no_welcome_and_publishes_nothing_unrecorded() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let joiner = CircleMember::new();
    let inbox = vec!["wss://inbox.finishonly-canary5b9e.example.com".to_string()];
    let invited = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            joiner.session(),
            &joiner.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox.clone(),
        nip65_relays: Vec::new(),
    };
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    // The invite is applied in a wake with room for its commit and none for
    // its Welcome, which keeps its route and waits for the next drive.
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let invite = within(&transport, &outbox, &clock, &FULL, ROW_BUDGET_MS)
        .add_members(&admin.circle, &group, &[invited])
        .await
        .expect("the invite is accepted");
    assert_eq!(
        (invite.status, invite.welcomes_sent, outbox.handed().len()),
        (EvolutionStatus::Confirmed, 0, 0),
        "premise: applied, and its Welcome not yet handed over",
    );

    let leave = sealed_by(&admin, &group, 1.0).await;
    let unrecorded = || DecryptedIngest {
        proposals: vec![leave.clone()],
        ..DecryptedIngest::default()
    };
    clock.set(HOUR_MS);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let _ = finish_only.resume(&admin.circle).await;
    let _ = finish_only
        .settle_staged(&admin.circle, Vec::new(), unrecorded())
        .await;
    assert!(
        outbox.handed().is_empty(),
        "a finish-only call published something that has no record",
    );

    let full = through(&transport, &outbox, &clock, &FULL);
    let _ = full.resume(&admin.circle).await;
    let _ = full
        .settle_staged(&admin.circle, Vec::new(), unrecorded())
        .await;
    let handed = outbox.handed();
    assert!(
        handed
            .iter()
            .any(|(event, relays)| event.kind.as_u16() == 1059 && relays == &inbox)
            && handed.iter().any(|(event, _)| event.id == leave.id),
        "premise: a full drive delivers the Welcome and publishes the proposal",
    );
}

/// An invite a finish-only call confirms keeps its Welcome on its record:
/// the commit is applied on the stored acknowledgement — the joiner is in the
/// roster — and nothing is handed to the publisher of what has no record.
/// The full drive that follows delivers the Welcome.
#[tokio::test]
async fn an_invite_a_finish_only_call_confirms_keeps_its_welcome_for_a_full_drive() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = epoch(&admin, &group).await;
    let joiner = CircleMember::new();
    let inbox = vec!["wss://inbox.finishonly-canary5b9e.example.com".to_string()];
    let invited = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            joiner.session(),
            &joiner.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox.clone(),
        nip65_relays: Vec::new(),
    };
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let invite = through(&transport, &outbox, &clock, &FULL)
        .add_members(&admin.circle, &group, &[invited])
        .await
        .expect("the invite is accepted");
    assert_eq!(invite.status, EvolutionStatus::Unresolved, "premise");
    transport.calls();

    clock.set(31 * SECOND_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && epoch(&admin, &group).await == before + 1
            && roster(&admin, &group).await.contains(&joiner.pubkey_hex()),
        "a finish-only call did not confirm an invite its relay acknowledged",
    );
    assert!(
        outbox.handed().is_empty(),
        "a finish-only confirm handed over a Welcome",
    );

    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        outbox
            .handed()
            .iter()
            .any(|(event, relays)| event.kind.as_u16() == 1059 && relays == &inbox),
        "the Welcome a finish-only confirm left on its record was not delivered by the full \
         drive that followed",
    );
}

/// A change asked of a finish-only call is refused, typed, before anything is
/// staged or queued: such a call makes no new commit.
#[tokio::test]
async fn a_change_asked_of_a_finish_only_call_is_refused_typed_and_nothing_is_staged() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let member = others[0].pubkey_hex();

    let refused = [
        finish_only
            .remove_members(&admin.circle, &group, std::slice::from_ref(&member))
            .await
            .err(),
        finish_only
            .update_relays(&admin.circle, &group, &[TWO.to_string()])
            .await
            .err(),
        finish_only
            .admin_handoff(&admin.circle, &group, &others[0].keys.public_key())
            .await
            .err(),
        finish_only.self_demote(&admin.circle, &group).await.err(),
        finish_only
            .repair_rotation(&admin.circle, &group)
            .await
            .err(),
        finish_only
            .add_members(&admin.circle, &group, &[])
            .await
            .err(),
    ];
    for answer in refused {
        assert!(
            matches!(answer, Some(CircleError::ForegroundOnly)),
            "a change asked of a finish-only call was not refused as foreground-only",
        );
    }
    assert!(
        records_of(&admin, &group).await.is_empty()
            && staged_ref(&admin, &group).await.is_none()
            && queued(&admin, &group).await == 0
            && transport.calls().is_empty(),
        "a refused change left something staged, queued or sent",
    );
}

// ── The receive and send entries in this mode ────────────────────────────────

/// A three-member circle whose admin has ingested a member's leave through a
/// finish-only poll and whose eviction of that member is now due: no commit of
/// its own was staged on the way, not even to be undone.
async fn a_departure_due_in_a_finish_only_plane(
) -> (CircleMember, Vec<CircleMember>, GroupId, ScriptedFanout) {
    let (admin, others, group, transport, _) = a_departure_due_with_its_leave().await;
    (admin, others, group, transport)
}

/// [`a_departure_due_in_a_finish_only_plane`], with the leave.
async fn a_departure_due_with_its_leave() -> (
    CircleMember,
    Vec<CircleMember>,
    GroupId,
    ScriptedFanout,
    nostr::Event,
) {
    let fx = setup_circle(3, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let _ = finish_only
        .ingest_for_poll(&admin.circle, &leave)
        .await
        .expect("the leave is ingested");
    for tick in 0..6_u32 {
        wait_out_the_engine(&admin, &group).await;
        let latitude = f64::from(tick).mul_add(0.25, 10.0);
        let fix = sealed_by(&others[1], &group, latitude).await;
        let polled = finish_only
            .ingest_for_poll(&admin.circle, &fix)
            .await
            .expect("a polled fix is ingested");
        assert!(
            has_fix(&polled.replayed, &others[1], latitude),
            "a finish-only poll did not hand back the fix it ingested",
        );
    }
    assert!(
        outbox.handed().is_empty() && newest_commit_row(&admin, &group).await.is_none(),
        "a finish-only poll staged a commit, or published something",
    );
    (admin, others, group, transport, leave)
}

/// [`a_departure_due_with_its_leave`], once another member's app has made
/// the eviction and this device has applied it from the background: the
/// engine still announces the eviction as due
/// (`docs/MDK_UPSTREAM_TRACKER.md` T-STALE-DEPARTURE-TIMER).
async fn a_departure_another_member_committed(
) -> (CircleMember, Vec<CircleMember>, GroupId, ScriptedFanout) {
    use helpers::stranded::{answer, staged};

    let (admin, others, group, transport, leave) = a_departure_due_with_its_leave().await;
    let (leaver, committer) = (&others[0], &others[1]);
    let source = epoch(&admin, &group).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let location = LocationMessage::new(51.5, -0.12);
    let held = finish_only
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    assert!(
        matches!(held.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
        "premise: with the departure uncommitted, a background send is held",
    );

    // Another member's app is open: it makes the eviction.
    assert!(matches!(
        answer(committer.session(), &leave).await,
        haven_core::nostr::mls::types::IngestOutcome::Processed
    ));
    wait_out_the_engine(committer, &group).await;
    let advanced = committer
        .session()
        .stage_unrecorded_for_test(&group)
        .await
        .expect("the other member's advance runs");
    let (eviction, pending) = staged(&advanced);
    committer
        .session()
        .confirm_published(pending)
        .await
        .expect("the eviction is confirmed");

    // This device applies it, still in the background.
    let _ = finish_only
        .ingest_for_poll(&admin.circle, &eviction)
        .await
        .expect("the eviction is ingested");
    for tick in 0..6_u32 {
        if epoch(&admin, &group).await > source {
            break;
        }
        wait_out_the_engine(&admin, &group).await;
        let fix = sealed_by(committer, &group, f64::from(tick).mul_add(0.25, 30.0)).await;
        let _ = finish_only
            .ingest_for_poll(&admin.circle, &fix)
            .await
            .expect("a polled fix is ingested");
    }
    assert!(
        epoch(&admin, &group).await == source + 1
            && !roster(&admin, &group).await.contains(&leaver.pubkey_hex())
            && admin
                .session()
                .eviction_due_after_for_test(&group)
                .await
                .is_some(),
        "premise: the eviction is applied, and the engine still announces one as due",
    );

    assert!(
        outbox.handed().is_empty(),
        "premise: nothing was published from the background",
    );
    (admin, others, group, transport)
}

/// A departure another member has already committed holds no send. A leave
/// arrives in the background and this device's sends for the circle are
/// held, since it may not make the eviction there; then a member whose app
/// is open makes it, and this device applies that commit — still in the
/// background. Its next send is sealed, at the new epoch, where the member
/// who left reads nothing.
///
/// The engine goes on announcing the eviction as due after that: its timer
/// is dropped where it applies a commit directly and not where a
/// convergence pass does, and only a full advance or a send's preflight
/// makes it look (`docs/MDK_UPSTREAM_TRACKER.md` T-STALE-DEPARTURE-TIMER). A
/// hold read from the timer alone would keep this device silent until its
/// own app was next opened.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_departure_another_member_has_committed_holds_no_background_send() {
    let (admin, others, group, transport) = a_departure_another_member_committed().await;
    let (leaver, committer) = (&others[0], &others[1]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let location = LocationMessage::new(51.5, -0.12);

    // A store that cannot say whether a departure still stands is read as
    // one in which it does: nothing is sealed for a member who may still
    // hold the epoch's keys. (The fault is injected: `test-utils` only.)
    wait_out_the_engine(&admin, &group).await;
    admin
        .session()
        .fail_store_for_test(StoreFault::Departure, true);
    let unsure = finish_only
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    admin
        .session()
        .fail_store_for_test(StoreFault::Departure, false);
    assert!(
        matches!(unsure.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
        "a location was sealed from the background while the store could not say whether a \
         departure still stood",
    );

    // Nor is one whose rows the read counts outnumber what it is bounded to:
    // past the bound it answers as that store does. A co-member's messages
    // for a future epoch are such rows — buffered on their header, never
    // decrypted (mdk#757). (The bound is set to one row: `test-utils` only.)
    let tip = epoch(&admin, &group).await;
    for ahead in [3_u64, 5] {
        let forged = committer
            .session()
            .forge_future_header_445_for_test(&group, tip + ahead)
            .await
            .expect("a co-member seals a message for a future epoch");
        let _ = finish_only
            .ingest_for_poll(&admin.circle, &forged)
            .await
            .expect("the message is ingested");
    }
    admin.session().cap_proposal_scan_for_test(1);
    let unread = finish_only
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    admin.session().cap_proposal_scan_for_test(usize::MAX);
    assert!(
        matches!(unread.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
        "a location was sealed from the background on a read of the circle's rows cut short \
         at its bound",
    );

    let sent = finish_only
        .seal_location(&admin.circle, &group, &location)
        .await
        .expect("the send is answered");
    let LocationSeal::Sealed { event, .. } = sent.seal else {
        panic!(
            "a departure another member had already committed held this device's \
             background send"
        );
    };
    assert!(
        reads(committer, &event).await && !reads(leaver, &event).await,
        "the send after the eviction is not sealed at the circle's new epoch",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none() && outbox.handed().is_empty(),
        "sealing after another member's eviction staged or published something",
    );
}

/// A busy circle's locations hold no background send behind a departure
/// another member has committed (`OWNER_ITEMS` 178/186): however many arrive
/// at the circle's epoch, the read that looks for a departure counts none of
/// them. (The bound is set to one row: `test-utils` only.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_busy_circles_locations_hold_no_background_send_behind_a_committed_departure() {
    let (admin, others, group, transport) = a_departure_another_member_committed().await;
    let (leaver, committer) = (&others[0], &others[1]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    for tick in 0..3_u32 {
        let fix = sealed_by(committer, &group, f64::from(tick).mul_add(0.25, 40.0)).await;
        let polled = finish_only
            .ingest_for_poll(&admin.circle, &fix)
            .await
            .expect("a polled fix is ingested");
        assert!(
            has_fix(
                &polled.replayed,
                committer,
                f64::from(tick).mul_add(0.25, 40.0)
            ),
            "premise: the fix is delivered at the circle's epoch",
        );
    }
    admin.session().cap_proposal_scan_for_test(1);
    wait_out_the_engine(&admin, &group).await;
    let sent = finish_only
        .seal_location(&admin.circle, &group, &LocationMessage::new(51.5, -0.12))
        .await
        .expect("the send is answered");
    let LocationSeal::Sealed { event, .. } = sent.seal else {
        panic!(
            "a busy circle's locations held a background send behind a departure another \
             member had already committed"
        );
    };
    assert!(
        reads(committer, &event).await && !reads(leaver, &event).await,
        "the send is not sealed at the circle's new epoch",
    );
}

/// Nor does an outsider's flood on the circle's routing tag: what no epoch
/// key opens is not a row the read counts, however much of it arrives.
/// (The bound is set to one row: `test-utils` only.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_outsiders_flood_on_the_routing_tag_holds_no_background_send() {
    let (admin, others, group, transport) = a_departure_another_member_committed().await;
    let (leaver, committer) = (&others[0], &others[1]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let routing = hex::encode(helpers::drive::ngid(&admin, &group).await);
    for _ in 0..3 {
        // Valid base64 of more than a nonce and a tag, sealed by no key the
        // circle holds.
        let junk = nostr::EventBuilder::new(nostr::Kind::Custom(445), "A".repeat(40))
            .tags([nostr::Tag::custom(
                nostr::TagKind::SingleLetter(nostr::SingleLetterTag::lowercase(nostr::Alphabet::H)),
                [routing.clone()],
            )])
            .sign_with_keys(&nostr::Keys::generate())
            .expect("sign");
        let _ = finish_only
            .ingest_for_poll(&admin.circle, &junk)
            .await
            .expect("the junk is taken");
    }
    admin.session().cap_proposal_scan_for_test(1);
    wait_out_the_engine(&admin, &group).await;
    let sent = finish_only
        .seal_location(&admin.circle, &group, &LocationMessage::new(51.5, -0.12))
        .await
        .expect("the send is answered");
    let LocationSeal::Sealed { event, .. } = sent.seal else {
        panic!("an outsider's junk on the routing tag held a background send");
    };
    assert!(
        reads(committer, &event).await && !reads(leaver, &event).await,
        "the send is not sealed at the circle's new epoch",
    );
}

/// A departure that still stands holds a background send after a restart:
/// the leave is unconsumed at the circle's epoch in the engine's store, and
/// nothing is sealed for the member who asked to leave.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_departure_that_stands_holds_a_background_send_after_a_restart() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    let admin = admin.reopen();
    wait_out_the_engine(&admin, &group).await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let held = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .seal_location(&admin.circle, &group, &LocationMessage::new(51.5, -0.12))
        .await
        .expect("the send is answered");
    assert!(
        matches!(held.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
        "a background send was not held by a departure still standing after a restart",
    );
    assert!(
        roster(&admin, &group)
            .await
            .contains(&others[0].pubkey_hex())
            && staged_ref(&admin, &group).await.is_none()
            && newest_commit_row(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && queued(&admin, &group).await == 0
            && outbox.handed().is_empty()
            && transport.calls().is_empty(),
        "a background send after a restart staged, sent or applied the eviction, or left \
         its fix queued",
    );
}

/// A finish-only poll applies what it ingests and makes nothing: a due
/// eviction is not staged, no record is written, nothing is owed the legacy
/// way and no relay is called, however many events it takes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_finish_only_poll_applies_what_it_ingests_and_stages_no_eviction() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    assert_eq!(
        admin
            .session()
            .eviction_due_after_for_test(&group)
            .await
            .map(|due| due.as_millis() < 60),
        Some(true),
        "premise: the eviction is due, or about to be",
    );
    assert!(
        records_of(&admin, &group).await.is_empty()
            && staged_ref(&admin, &group).await.is_none()
            && transport.calls().is_empty()
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex()),
        "a finish-only poll staged, recorded, owed or sent an eviction",
    );
}

/// A finish-only send is not made while an eviction is due: nothing is staged
/// — not even to be undone — and the answer says what holds the circle. The
/// full send that follows records the eviction, sends it, and the one after
/// is sealed at the epoch the member who left cannot read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_finish_only_send_is_not_made_while_an_eviction_is_due_and_stages_nothing() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let fix = LocationMessage::new(51.5, -0.12);

    for _ in 0..3 {
        wait_out_the_engine(&admin, &group).await;
        let sent = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
            .seal_location(&admin.circle, &group, &fix)
            .await
            .expect("the call runs");
        assert!(
            matches!(sent.seal, LocationSeal::Deferred(SendHeld::DepartureDue)),
            "a finish-only send with an eviction due was not answered as held by it",
        );
        assert!(staged_ref(&admin, &group).await.is_none());
    }
    assert!(
        newest_commit_row(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && transport.calls().is_empty()
            && queued(&admin, &group).await == 0,
        "a finish-only send staged the eviction, left a fix queued, or called a relay",
    );

    // The full mode makes the eviction: recorded in the send's own hold,
    // sent, applied on the relay's word.
    let full = through(&transport, &outbox, &clock, &FULL);
    let made = full
        .seal_location(&admin.circle, &group, &fix)
        .await
        .expect("the call runs");
    assert!(matches!(
        made.seal,
        LocationSeal::Deferred(SendHeld::Nothing)
    ));
    assert_eq!(transport.calls().len(), 1);
    assert!(!roster(&admin, &group)
        .await
        .contains(&others[0].pubkey_hex()));
    let sealed = full
        .seal_location(&admin.circle, &group, &fix)
        .await
        .expect("the call runs");
    let LocationSeal::Sealed { event, .. } = sealed.seal else {
        panic!("the send after the eviction was applied is not sealed");
    };
    assert!(
        !helpers::drive::reads(&others[0], &event).await,
        "the member who left reads a location sealed after its eviction",
    );
}

// ── Nothing is made behind a foreground that has ended ───────────────────────
//
// A pass decides on the full mode and then waits — for the engine, which a
// whole hand-back of stranded input can be holding. A commit staged behind
// a foreground that ended in that wait is one a paused plane made: no call
// that only finishes ever sends it for the first time, so its circle would
// stand pending, parking everything it receives unread, for as long as the
// app stayed away. Each site that can make one asks the mode again with the
// engine held.

/// A drive does not stage an eviction left due once the foreground it began
/// in has ended: nothing is recorded, no relay is called, and the next full
/// drive makes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_left_due_is_not_staged_by_a_drive_whose_foreground_ended_as_it_waited() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&group);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    wait_out_the_engine(&admin, &group).await;

    let mode = NarrowsWhenHeld::after(&admin, 0);
    let _ = through(&transport, &outbox, &clock, &mode)
        .resume(&admin.circle)
        .await;
    assert!(
        mode.narrowed(),
        "premise: the drive asked its mode again with the engine held",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && newest_commit_row(&admin, &group).await.is_none()
            && transport.calls().is_empty(),
        "an eviction left due was staged by a drive whose foreground had ended while it \
         waited for the engine",
    );

    wait_out_the_engine(&admin, &group).await;
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        !roster(&admin, &group)
            .await
            .contains(&others[0].pubkey_hex()),
        "control: the next full drive makes the eviction",
    );
}

/// Nor once the foreground has ended AFTER the drive had the engine: the
/// advance hands the circle's stranded input back before it is made, which
/// takes as long as it takes, and asks again with nothing awaited between
/// the answer and the commit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_left_due_is_not_staged_once_the_foreground_ended_in_the_hand_back() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&group);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    wait_out_the_engine(&admin, &group).await;

    // Still the foreground's when the drive first has the engine; ended by
    // the next time it asks.
    let mode = NarrowsWhenHeld::after(&admin, 1);
    let _ = through(&transport, &outbox, &clock, &mode)
        .resume(&admin.circle)
        .await;
    assert!(
        mode.narrowed(),
        "premise: the drive asked its mode a second time with the engine held",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && newest_commit_row(&admin, &group).await.is_none()
            && transport.calls().is_empty(),
        "an eviction left due was staged behind a foreground that had ended while the \
         circle's stranded input was handed back",
    );

    wait_out_the_engine(&admin, &group).await;
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        !roster(&admin, &group)
            .await
            .contains(&others[0].pubkey_hex()),
        "control: the next full drive makes the eviction",
    );
}

/// The advance a fold makes for what a batch leaves owing — here a polled
/// event's — stages nothing either once the foreground that asked for it
/// has ended: the event is applied, and the eviction waits.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_folds_advance_stages_nothing_once_the_foreground_that_asked_for_it_has_ended() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    wait_out_the_engine(&admin, &group).await;

    let fix = sealed_by(&others[1], &group, 33.0).await;
    let mode = NarrowsWhenHeld::after(&admin, 0);
    let polled = through(&transport, &outbox, &clock, &mode)
        .ingest_for_poll(&admin.circle, &fix)
        .await
        .expect("the poll runs");
    assert!(
        mode.narrowed() && has_fix(&polled.replayed, &others[1], 33.0),
        "premise: the event was applied, and the fold's advance asked its mode again",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && newest_commit_row(&admin, &group).await.is_none()
            && transport.calls().is_empty(),
        "a fold's advance staged an eviction after the foreground that asked for it had ended",
    );

    wait_out_the_engine(&admin, &group).await;
    let next = sealed_by(&others[1], &group, 34.0).await;
    let _ = through(&transport, &outbox, &clock, &FULL)
        .ingest_for_poll(&admin.circle, &next)
        .await
        .expect("the poll runs");
    assert!(
        !roster(&admin, &group)
            .await
            .contains(&others[0].pubkey_hex()),
        "control: a full poll's advance makes the eviction",
    );
}

/// A send decided in the foreground and made behind a wait in which the
/// foreground ended is a send that makes no commit: the eviction its
/// preflight stages is undone in that hold, unsent and unrecorded, and the
/// answer says what holds the circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_records_no_eviction_once_the_foreground_that_asked_for_it_has_ended() {
    let (admin, _others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let fix = LocationMessage::new(51.5, -0.12);
    wait_out_the_engine(&admin, &group).await;

    let mode = NarrowsWhenHeld::after(&admin, 0);
    let sent = through(&transport, &outbox, &clock, &mode)
        .seal_location(&admin.circle, &group, &fix)
        .await
        .expect("the call runs");
    assert!(
        mode.narrowed(),
        "premise: the send asked its mode again with the engine held",
    );
    assert!(
        matches!(sent.seal, LocationSeal::Deferred(SendHeld::DepartureDue))
            && staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && transport.calls().is_empty()
            && queued(&admin, &group).await == 0,
        "a send whose foreground had ended while it waited for the engine recorded the \
         eviction its preflight staged, sent something, or was not answered as held",
    );

    wait_out_the_engine(&admin, &group).await;
    let control = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix)
        .await
        .expect("the call runs");
    assert!(
        matches!(control.seal, LocationSeal::Deferred(SendHeld::Nothing))
            && transport.calls().len() == 1,
        "control: the full send records the eviction and sends it",
    );
}

/// A confirm made by a call that only finishes makes nothing new either,
/// whatever its replay brings in. The next member's leave was parked behind
/// the eviction this device had sent; the narrow confirm of that eviction
/// applies the leave, which makes the NEXT eviction due — and leaves it so:
/// nothing is staged, recorded or sent for it until a full drive.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_next_eviction_of_a_cascade_is_left_due_by_the_narrow_confirm_that_brings_it() {
    use helpers::stranded::{answer, parks};
    use nostr::JsonUtil as _;

    let fx = setup_circle(4, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    let (first, second, witness) = (&others[0], &others[1], &others[2]);
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&group);
    let source = epoch(&admin, &group).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent, Answer::Accepted, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);

    // The first eviction is made in the foreground and sent once: no relay
    // answers.
    let full = through(&transport, &outbox, &clock, &FULL);
    let _ = full
        .ingest_for_poll(&admin.circle, &leave)
        .await
        .expect("the leave is ingested");
    for _ in 0..6 {
        if staged_ref(&admin, &group).await.is_some() {
            break;
        }
        wait_out_the_engine(&admin, &group).await;
        let _ = full.resume(&admin.circle).await;
    }
    let sent = transport.calls();
    assert!(
        staged_ref(&admin, &group).await.is_some() && sent.len() == 1,
        "premise: the first eviction is recorded and was sent once",
    );
    let eviction = nostr::Event::from_json(&sent[0].payload).expect("the event that was sent");

    // The rest of the circle applies it, and the next member leaves.
    for member in [second, witness] {
        assert!(matches!(
            answer(member.session(), &leave).await,
            haven_core::nostr::mls::types::IngestOutcome::Processed
        ));
        member
            .session()
            .process_event_settled_for_test(&eviction)
            .await
            .expect("the member applies the eviction");
    }
    let next_leave = second
        .circle
        .propose_leave(&group)
        .await
        .expect("the next member proposes its leave")
        .expect("a first leave in this epoch proposes");
    assert!(
        parks(admin.session(), &next_leave).await,
        "premise: parked behind this device's own pending eviction",
    );

    // A relay acknowledges, and the confirm is a call's that only finishes.
    clock.set(31 * SECOND_MS);
    let _ = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .resume(&admin.circle)
        .await;
    assert!(
        epoch(&admin, &group).await == source + 1
            && !roster(&admin, &group).await.contains(&first.pubkey_hex()),
        "premise: the first eviction was confirmed by the call that only finishes",
    );
    transport.calls();

    // Its replay applied the next leave, whose eviction comes due — and
    // nothing is made of it, poll after poll, drive after drive.
    for tick in 0..4_u32 {
        wait_out_the_engine(&admin, &group).await;
        let fix = sealed_by(witness, &group, f64::from(tick).mul_add(0.25, 15.0)).await;
        let narrow = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
        let _ = narrow
            .ingest_for_poll(&admin.circle, &fix)
            .await
            .expect("a polled fix is ingested");
        let _ = narrow.resume(&admin.circle).await;
    }
    assert!(
        admin
            .session()
            .eviction_due_after_for_test(&group)
            .await
            .is_some(),
        "premise: the next eviction is due",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group)
                .await
                .iter()
                .all(|record| record.mls != FanoutMls::Pending)
            && transport.calls().is_empty()
            && roster(&admin, &group).await.contains(&second.pubkey_hex()),
        "a call that only finishes made the next eviction of a cascade after confirming the \
         one before it",
    );

    wait_out_the_engine(&admin, &group).await;
    let _ = full.resume(&admin.circle).await;
    assert!(
        !roster(&admin, &group).await.contains(&second.pubkey_hex()),
        "control: the next full drive makes the eviction the narrow confirm left due",
    );
}

/// The one way a commit reaches a finish-only hold is a preflight that raced
/// the departure check. It is undone in that hold, unsent and unrecorded,
/// its circle named as waiting, and the line that says so names nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_found_staged_by_a_finish_only_hold_is_undone_unsent_and_said() {
    let (admin, others, group, transport) = a_departure_due_in_a_finish_only_plane().await;
    wait_out_the_engine(&admin, &group).await;
    let mut staged = None;
    let lines = capture_haven_log(async {
        staged = Some(
            admin
                .session()
                .send_location_staging_for_test(&group, "{}".to_owned(), 1, FINISH_ONLY)
                .await
                .expect("the send runs"),
        );
    })
    .await;
    let staged = staged.expect("ran");
    assert!(
        staged.fanouts.is_empty() && staged.waiting == [group.clone()],
        "a finish-only hold recorded a commit, or did not say its circle is waiting",
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && transport.calls().is_empty(),
    );
    let said: Vec<_> = lines
        .iter()
        .filter(|line| {
            line.message
                .contains("a commit found staged by a drive that makes none is undone unsent")
        })
        .cloned()
        .collect();
    assert_eq!(said.len(), 1, "the undo was not said once");
    assert_no_needles(
        &said,
        &[
            &hex::encode(group.as_slice()),
            &others[0].pubkey_hex(),
            &admin.pubkey_hex(),
            CANARY,
        ],
    );
}

/// A leave is not proposed again by a finish-only call. The engine mints the
/// user's own leave again, for the epoch a commit has just reached, in the
/// full advance's maintenance; the inputs-only advance that applies the
/// commit here does not. Nothing is lost: the engine's leave request stands,
/// and the next full advance mints the proposal, records it, and a full
/// drive sends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_is_proposed_again_by_the_full_advance_and_never_by_a_finish_only_call() {
    let fx = setup_circle(3, &[ONE]).await;
    let _first = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    let leaver = &others[0];
    // The admin commits without having seen the leave.
    let commit = admin
        .circle
        .update_relays_for_test(&group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change is staged");

    let transport = ScriptedFanout::default();
    for relay in [ONE, TWO] {
        transport.answer(relay, [Answer::Accepted]);
    }
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let before = epoch(leaver, &group).await;
    let polled = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS)
        .ingest_for_poll(&leaver.circle, &commit)
        .await
        .expect("the commit is ingested");
    assert!(!polled.errored);
    assert_eq!(epoch(leaver, &group).await, before + 1, "premise: applied");
    assert!(
        records_of(leaver, &group).await.is_empty()
            && transport.calls().is_empty()
            && outbox.handed().is_empty(),
        "a finish-only call proposed the leave again, recorded it or sent it",
    );

    let advanced = leaver
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the full advance runs");
    assert_eq!(
        advanced.proposals.len(),
        1,
        "the full advance did not mint the leave again under a record",
    );
    let record = records_of(leaver, &group).await.remove(0);
    assert_eq!(record.mls, FanoutMls::NotApplicable);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&leaver.circle)
        .await;
    let sent = transport.calls();
    assert!(
        !sent.is_empty() && sent.iter().all(|call| call.event_id == record.event_id),
        "a full drive did not send the recorded leave",
    );
}
