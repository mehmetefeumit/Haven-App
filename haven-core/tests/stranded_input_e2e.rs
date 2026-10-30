//! What Haven does about input the engine left stranded
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY; what MDK itself does is
//! measured in `stranded_input_measured_e2e.rs`).
//!
//! It tells the circle, durably, where it finds such input — at the open and
//! after every confirm and rollback — and hands it back to the engine ahead
//! of the next thing a receive plane ingests or advances: each event kept in
//! Haven's own store, the engine's row released through MDK's own
//! `release_message_for_replay`, the event ingested as a relay's delivery is,
//! and the kept copy ended on an answer that says the engine judged the
//! event or holds it again.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted and
//! counts every call; nothing is dialled. "The process ends" is the member's
//! stores closed and opened again.

mod helpers;

use cgka_engine::message_processor::MAX_PEEL_DEFERRED_ROWS_PER_GROUP;
use haven_core::circle::CIRCLES_DB_FILENAME;
use haven_core::nostr::mls::storage::{
    forge_stored_event_signature_for_test, released_receipts_and_account_rows_for_test,
    set_new_stored_message_fault_for_test, set_new_stored_message_fault_naming_for_test,
    set_stored_message_delete_fault_for_test, set_stored_message_write_fault_naming_for_test,
};
use haven_core::nostr::mls::types::{GroupId, IngestOutcome};
use haven_core::nostr::mls::{
    max_rewind_commits, ChangeNote, HandBackStop, StoreFault, HAND_BACK_SLICE, HAND_BACK_WHOLE,
    KEPT_BYTES_PER_CIRCLE, KEPT_EVENTS_PER_CIRCLE,
};
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{DriveMode, FanoutClock as _, ROW_BUDGET_MS};
use haven_core::relay::live_sync::{
    group_cursor_stream, EngineProcessor, EventBus, GroupProcessOutcome, LiveSyncEvent,
};
use haven_core::relay::{allow_ws_loopback_for_test, ReceiveOnlyOutcome, RelayManager};
use helpers::drive::{
    epoch, has_fix, ngid, reads, records_of, roster, sealed_by, staged_ref, through, within,
    ManualClock, Recorder,
};
use helpers::stranded::{
    a_fix_from_an_epoch_not_reached_stranded, a_removal_a_running_process_stranded,
    a_stranded_leave, a_stranded_leave_behind, a_stranded_removal,
    a_stranded_removal_behind_a_flood, a_stranded_rival, all_parked_at, answer, bare, co_admin,
    confirm_and_die, fixes, fixes_stranded_by_a_confirm, fixes_stranded_by_a_rollback,
    fixes_stranded_by_a_rollback_on, held, latitude_of, mls_db, parks, served, split, stage_relays,
    staged, unopenable, unopened_retryable, CANARY, LATER, ONE, THREE, TWO,
};
use helpers::{assert_no_needles, capture_haven_log, found_circle, setup_circle, CircleMember};

const FULL: DriveMode = DriveMode::Full;
const FINISH_ONLY: DriveMode = DriveMode::FinishOnly;

/// What `member`'s circle has been told the engine holds unread.
fn unread(member: &CircleMember, group: &GroupId) -> Vec<ChangeNote> {
    let mut notes = member.session().peek_change_notes(group);
    notes.retain(|note| matches!(note, ChangeNote::UnreadChange | ChangeNote::UnreadLocation));
    notes
}

/// What Haven keeps for `group`, in the order kept: for each entry, whether
/// the engine has been handed it and did not take it.
fn kept(member: &CircleMember, group: &GroupId) -> Vec<bool> {
    member.session().kept_input_for_test(group)
}

async fn stranded(member: &CircleMember, group: &GroupId) -> usize {
    unopened_retryable(&held(member.session(), group).await)
}

/// Whether `member`, asked the legacy way for a location for `group`, seals
/// none and says so typed: the engine queued the send behind what its
/// circle has not settled.
async fn seal_is_deferred(member: &CircleMember, group: &GroupId, latitude: f64) -> bool {
    matches!(
        member
            .circle
            .seal_location_for_test(
                group,
                &haven_core::location::LocationMessage::new(latitude, 2.0)
            )
            .await,
        Err(haven_core::circle::CircleError::EngineHeld)
    )
}

/// Whether a location asked of the driver for `group`, in a plane that
/// makes no commit and inside a wake, is answered at all.
async fn bounded_seal(member: &CircleMember, group: &GroupId) -> bool {
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    within(&transport, &outbox, &clock, &FINISH_ONLY, 4 * ROW_BUDGET_MS)
        .seal_location(
            &member.circle,
            group,
            &haven_core::location::LocationMessage::new(30.5, 2.0),
        )
        .await
        .is_ok()
}

/// A location `sender` seals at `latitude`, carrying `timestamp` as the
/// time it was taken.
async fn sealed_at(
    sender: &CircleMember,
    group: &GroupId,
    latitude: f64,
    timestamp: chrono::DateTime<chrono::Utc>,
) -> nostr::Event {
    let mut location = haven_core::location::LocationMessage::new(latitude, 2.0);
    location.timestamp = timestamp;
    sender
        .circle
        .seal_location_for_test(group, &location)
        .await
        .expect("the member seals a location")
        .0
}

/// A plain connection onto `member`'s circle store, which a test circle
/// keeps unencrypted.
fn circle_store(member: &CircleMember) -> rusqlite::Connection {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(member.dir.path().join(CIRCLES_DB_FILENAME))
        .expect("the circle store opens")
}

/// Whether `delivered` is exactly the stranded fixes of `senders`, once
/// each, in the order they arrived.
fn in_arrival_order(
    delivered: &[haven_core::nostr::mls::types::LocationMessageResult],
    senders: &[CircleMember],
) -> bool {
    delivered.len() == senders.len()
        && senders
            .iter()
            .enumerate()
            .all(|(index, sender)| has_fix(&delivered[index..=index], sender, latitude_of(index)))
}

// ── Told, then handed back ───────────────────────────────────────────────────

/// A fix a kill left stranded is noted when the store is opened — before
/// anything is done about it — and handed back to the engine ahead of the
/// first advance any plane makes: delivered once, in arrival order, with
/// nothing left parked, nothing kept, and the note gone. A redelivery of it
/// is then a duplicate.
///
/// MDK's release is a bare delete here: it journals a receipt only for a
/// host of its own, and fails once that journal is full. Were a pin bump to
/// change that, a journal nobody reads would fill and every release fail.
#[tokio::test]
async fn a_stranded_fix_is_noted_at_the_open_and_handed_back_ahead_of_the_first_advance() {
    let (admin, others, group, source, parked) = fixes_stranded_by_a_confirm(2).await;
    let admin = admin.reopen();
    assert_eq!(
        unread(&admin, &group),
        [ChangeNote::UnreadLocation],
        "a circle the open found holding stranded fixes was not told, or was told of a \
         membership change",
    );
    assert!(
        all_parked_at(&held(admin.session(), &group).await, 2, source)
            && kept(&admin, &group).is_empty(),
        "the open itself took something over: the note must stand before any release",
    );

    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        in_arrival_order(&fixes(&advanced), &others),
        "the stranded fixes were not handed back once each, in the order they arrived, \
         ahead of the advance",
    );
    assert!(
        stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "after the hand-back a row is still parked, a copy is still kept, or the note \
         still stands",
    );
    assert!(
        matches!(
            answer(admin.session(), &parked[0]).await,
            IngestOutcome::Ignored { .. }
        ),
        "a handed-back event delivered again is not a duplicate",
    );
    let (db, key) = mls_db(admin.dir.path());
    assert_eq!(
        released_receipts_and_account_rows_for_test(&db, &key).expect("read"),
        (0, 0),
        "MDK's release journalled a receipt, or Haven's store has an account projection: \
         nobody consumes that journal, and at 8 192 rows every release fails",
    );
}

/// The line that says a circle holds stranded input names nothing.
#[tokio::test]
async fn the_line_that_tells_of_stranded_input_names_no_circle_and_no_event() {
    let (admin, others, group, _, parked) = fixes_stranded_by_a_confirm(1).await;
    let (keys, dir) = (admin.keys.clone(), admin.dir.path().to_path_buf());
    let mut reopened = None;
    let lines = capture_haven_log(async {
        reopened = Some(admin.reopen());
    })
    .await;
    let admin = reopened.expect("reopened");
    // Every line of the capture, whoever wrote it: the other tests of this
    // file say the same thing of their own circles while this one listens.
    assert!(
        lines.iter().any(|line| line.message.contains("[Stranded]")),
        "stranded input was not said",
    );
    assert_no_needles(
        &lines,
        &[
            &hex::encode(group.as_slice()),
            &parked[0].id.to_hex(),
            &others[0].pubkey_hex(),
            &keys.public_key().to_hex(),
            &dir.to_string_lossy(),
            CANARY,
        ],
    );
    assert_eq!(unread(&admin, &group), [ChangeNote::UnreadLocation]);
}

/// A peer's commit a kill left stranded: told as a membership change this
/// device has not applied, and handed back before this device seals
/// anything. The very first location it is asked for after the open — with
/// no receive call in between — is either not sealed yet, or sealed where
/// the member that commit removed cannot read it. Then the device is on its
/// circle's epoch, reads what the circle sends, and nothing says "out of
/// step" afterwards.
#[tokio::test]
async fn a_stranded_commit_is_handed_back_and_the_device_seals_at_its_circles_epoch() {
    let (admin, peer, removed, group, source, _) = a_stranded_removal(true).await;
    let admin = admin.reopen();
    assert_eq!(
        unread(&admin, &group),
        [ChangeNote::UnreadChange],
        "a circle holding a stranded commit was not told of a change it has not applied",
    );
    // The first seal after the open, with no receive call before it: the
    // removal is handed back first, so the engine queues the send behind it
    // and nothing is sealed for the removed member.
    assert!(
        seal_is_deferred(&admin, &group, 51.5).await,
        "the first location asked for after the open was sealed at the epoch its circle \
         has left, or refused untyped",
    );
    assert!(
        stranded(&admin, &group).await == 0 && kept(&admin, &group).is_empty(),
        "the first seal after the open did not hand the stranded commit back first",
    );

    let _ = served(admin.session(), &group).await;
    assert_eq!(
        epoch(&admin, &group).await,
        source + 2,
        "the stranded commit was not applied once handed back",
    );
    let later = sealed_by(&peer, &group, 52.5).await;
    assert!(
        matches!(
            answer(admin.session(), &later).await,
            IngestOutcome::Processed
        ),
        "after the hand-back the device still cannot read its circle",
    );
    let sealed = sealed_by(&admin, &group, 53.5).await;
    assert!(
        reads(&peer, &sealed).await && !reads(&removed, &sealed).await,
        "after the hand-back the removed member still reads this device, or its circle cannot",
    );
    assert!(
        admin.session().peek_change_notes(&group).is_empty()
            && stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty(),
        "a note still stands for a circle that holds nothing unread",
    );
}

/// The same in a running process: a confirm whose replay ended on an error
/// ahead of a peer's removal leaves the removal stranded, and the next
/// location this device is asked for — no open, no receive call — is not
/// sealed for the removed member.
#[tokio::test]
async fn a_seal_right_after_the_confirm_that_stranded_a_removal_is_not_for_the_removed_member() {
    let (admin, peer, removed, group) = a_removal_a_running_process_stranded().await;
    assert!(
        unread(&admin, &group).contains(&ChangeNote::UnreadChange),
        "premise: the confirm that stranded the removal told its circle in the same call",
    );
    assert!(
        seal_is_deferred(&admin, &group, 51.5).await,
        "a location asked for right after the confirm was sealed at the epoch its circle has \
         left, or refused untyped",
    );
    assert!(
        unread(&admin, &group).is_empty() && kept(&admin, &group).is_empty(),
        "a seal in the process that stranded a removal did not hand it back first",
    );
    let _ = served(admin.session(), &group).await;
    let sealed = sealed_by(&admin, &group, 53.5).await;
    assert!(
        reads(&peer, &sealed).await && !reads(&removed, &sealed).await,
        "after the hand-back the removed member still reads this device, or its circle cannot",
    );
}

/// A change of the group made while a peer's commit stands stranded is not
/// staged from the epoch the circle has left: the commit is handed back
/// first, and the change is then made at the circle's epoch or not made at
/// all — never as a rival to the commit the circle has already applied. The
/// same for this device's own leave.
#[tokio::test]
async fn a_change_or_a_leave_asked_while_a_commit_stands_stranded_is_never_staged_from_the_epoch_left(
) {
    for leave in [false, true] {
        let (admin, peer, _removed, group, source, _) = a_stranded_removal(true).await;
        let admin = admin.reopen();
        let staged_at = if leave {
            let _ = admin.session().leave_group(&group).await;
            None
        } else {
            admin
                .session()
                .update_relays(&group, vec![ONE.to_owned(), THREE.to_owned()])
                .await
                .ok()
                .and_then(|effects| helpers::stranded::try_staged(&effects))
                .map(|_| ())
        };
        assert!(
            stranded(&admin, &group).await == 0 && kept(&admin, &group).is_empty(),
            "a change asked while a commit stood stranded did not hand it back first",
        );
        let _ = served(admin.session(), &group).await;
        // The circle's removal is applied here whatever became of the change:
        // it was never made a rival of.
        let applied = admin
            .session()
            .member_pubkeys(&group)
            .await
            .expect("roster");
        assert!(
            applied.len() == 2 && applied.contains(&peer.pubkey_hex()),
            "the circle's commit was not applied on a device that then asked for a change",
        );
        if staged_at.is_some() {
            assert!(
                epoch(&admin, &group).await > source + 1,
                "a change was staged from the epoch the circle had left",
            );
        }
    }
}

/// A stranded rival commit that the rest of the circle kept: handed back,
/// the engine takes the circle's branch, and the device and its circle read
/// each other again.
#[tokio::test]
async fn a_stranded_rival_that_won_is_handed_back_and_the_device_takes_its_circles_branch() {
    let (stranded_device, rival, group, _) = a_stranded_rival(false).await;
    let device = stranded_device.reopen();
    let circle_relays = rival.session().group_relays(&group).await.expect("relays");
    assert!(
        device.session().group_relays(&group).await.expect("relays") != circle_relays
            && unread(&device, &group) == [ChangeNote::UnreadChange],
        "premise: alone on a branch of its own, and told",
    );

    let _ = served(device.session(), &group).await;
    assert_eq!(
        device.session().group_relays(&group).await.expect("relays"),
        circle_relays,
        "the stranded rival was handed back and the device is still on its own branch",
    );
    let from_circle = sealed_by(&rival, &group, 62.5).await;
    let sealed = sealed_by(&device, &group, 63.5).await;
    assert!(
        matches!(
            answer(device.session(), &from_circle).await,
            IngestOutcome::Processed
        ) && reads(&rival, &sealed).await
            && unread(&device, &group).is_empty(),
    );
}

/// A stranded leave is handed back AHEAD of the eviction that names it, in
/// the very ingest that takes the eviction: the eviction then applies. Left
/// stranded it would have made that eviction unappliable for good
/// (`stranded_input_measured_e2e.rs`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stranded_leave_is_handed_back_ahead_of_the_eviction_that_names_it() {
    let (admin, others, group, source, eviction) = a_stranded_leave(true).await;
    let (committer, leaver) = (&others[0], &others[1]);
    let admin = admin.reopen();
    assert_eq!(unread(&admin, &group), [ChangeNote::UnreadChange]);

    let _ = answer(admin.session(), &eviction).await;
    let _ = served(admin.session(), &group).await;
    assert_eq!(
        epoch(&admin, &group).await,
        source + 2,
        "the eviction did not apply: the leave it names was not handed back ahead of it",
    );
    let from_circle = sealed_by(committer, &group, 34.5).await;
    let sealed = sealed_by(&admin, &group, 35.5).await;
    assert!(
        matches!(
            answer(admin.session(), &from_circle).await,
            IngestOutcome::Processed
        ) && reads(committer, &sealed).await
            && !reads(leaver, &sealed).await
            && unread(&admin, &group).is_empty(),
    );
}

/// However much stands stranded ahead of a leave, the leave is opened before
/// the eviction that names it is taken: a call that takes its circle's
/// stranded input whole hands all of it back first, and one that may not
/// wait that out takes sixteen and does not take the eviction at all until
/// the rest has been handed back. Either way the eviction applies.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_is_never_taken_ahead_of_its_leave_however_much_is_stranded_before_it() {
    const AHEAD: usize = 17;
    for whole in [true, false] {
        let (admin, _others, group, source, eviction) = a_stranded_leave_behind(true, AHEAD).await;
        let admin = admin.reopen();
        if whole {
            let _ = answer(admin.session(), &eviction).await;
        } else {
            let first = admin
                .session()
                .process_event_staging_for_test(&eviction, 1, &FINISH_ONLY)
                .await;
            assert!(
                matches!(first, Err(haven_core::nostr::NostrError::EngineHeld))
                    && stranded(&admin, &group).await == AHEAD + 1 - 16,
                "a call that could not hand back the whole of its circle's stranded input \
                 took the eviction all the same, or did not stop at sixteen",
            );
            let second = admin
                .session()
                .process_event_staging_for_test(&eviction, 1, &FINISH_ONLY)
                .await;
            assert!(second.is_ok(), "the next call did not carry on");
        }
        assert!(
            stranded(&admin, &group).await == 0 && kept(&admin, &group).is_empty(),
            "premise: everything stranded was handed back",
        );
        let _ = served(admin.session(), &group).await;
        assert_eq!(
            epoch(&admin, &group).await,
            source + 2,
            "the eviction did not apply: it was taken ahead of the leave it names",
        );
    }
}

/// What a location asked of `member` the legacy way for `group` came back
/// as: the sealed event, or `None` for the typed deferral. Anything else —
/// a held seal answered as a failure — fails the test.
async fn seal_or_deferral(
    member: &CircleMember,
    group: &GroupId,
    latitude: f64,
) -> Option<nostr::Event> {
    let sealed = member
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(latitude, 2.0),
        )
        .await;
    assert!(
        matches!(
            sealed,
            Ok(_) | Err(haven_core::circle::CircleError::EngineHeld)
        ),
        "a seal that was not made was answered as a failure, not a deferral",
    );
    sealed.ok().map(|(event, _, _)| event)
}

/// With any number of an outsider's events parked ahead of it, a stranded
/// removal is handed back within a number of calls the flood's size and the
/// call's room give, and no location is sealed for the removed member
/// meanwhile.
///
/// The outsider needs the circle's routing tag and nothing else: it fills
/// the engine's store of what it cannot open (2048 rows a circle, v0.10.4
/// `cgka-engine/src/message_processor/mod.rs` 89), then sends more while a
/// commit of this device's is pending — more than a circle may keep, and
/// more than one call hands back. Handed back, each is refused by the engine
/// for want of room, and ends: it is owed its refetch by id, and nothing of
/// it is kept to stand in front of the removal. Every seal on the way is
/// answered as a deferral. In the foreground a call hands back
/// [`HAND_BACK_WHOLE`] events before it answers held, and in a plane that
/// makes no commit [`HAND_BACK_SLICE`].
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_outsiders_flood_cannot_keep_a_stranded_removal_from_being_handed_back() {
    const FLOOD: usize = KEPT_EVENTS_PER_CIRCLE + 44;
    for burst in [false, true] {
        let (admin, peer, removed, group, source, forged) =
            a_stranded_removal_behind_a_flood(FLOOD).await;
        let admin = admin.reopen();
        assert!(
            stranded(&admin, &group).await == FLOOD + 1 && !unread(&admin, &group).is_empty(),
            "premise: the flood and the removal behind it are stranded, and the circle told",
        );
        // The plane this device's own sends are made beside: the foreground,
        // or a background burst, which makes no commit.
        let plane = EngineProcessor::new(std::sync::Arc::clone(&admin.circle), EventBus::new());
        plane.for_test().set_background_burst(burst);
        let room = if burst {
            HAND_BACK_SLICE
        } else {
            HAND_BACK_WHOLE
        };

        if !burst {
            // One call's room, and no more, with the engine held.
            let held_back = admin.session().advance_for_receive(&group).await;
            assert!(
                matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
                    && stranded(&admin, &group).await == FLOOD + 1 - HAND_BACK_WHOLE,
                "a call in the foreground handed back more of its circle than its room, or \
                 took its own turn ahead of what the circle was still owed",
            );
        }
        if burst {
            // The app's own legacy call beside a burst is a call inside a
            // wake too: sixteen, with the engine held, and no more — also
            // one that asks for the whole of its circle in the foreground.
            let held_back = admin.session().advance_for_receive(&group).await;
            assert!(
                matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
                    && stranded(&admin, &group).await == FLOOD + 1 - HAND_BACK_SLICE,
                "a legacy advance beside a burst handed back more than a wake's slice of its \
                 circle with the engine held",
            );
            assert!(
                seal_or_deferral(&admin, &group, 39.0).await.is_none()
                    && stranded(&admin, &group).await == FLOOD + 1 - 2 * HAND_BACK_SLICE,
                "a legacy seal beside a burst handed back more than a wake's slice of its \
                 circle with the engine held",
            );
        }
        let mut sealed = None;
        let mut asked = 0;
        // Every call hands back its room's worth at least; a few more are
        // allowed for the commit's own pass to close once it has been
        // handed back.
        let calls = (FLOOD + 1).div_ceil(room) + 6;
        while sealed.is_none() {
            asked += 1;
            assert!(
                asked <= calls,
                "the removal was not handed back, and a location sealed behind it, within \
                 the calls the flood's size gives: an outsider held the hand-back open",
            );
            sealed = seal_or_deferral(&admin, &group, 40.0).await;
            if let Some(event) = &sealed {
                assert!(
                    !reads(&removed, event).await,
                    "a location was sealed for the removed member while the removal that \
                     ends its epoch stood stranded behind an outsider's events",
                );
            } else if stranded(&admin, &group).await == 0 {
                let _ = served(admin.session(), &group).await;
            }
        }
        let sealed = sealed.expect("sealed");
        assert!(
            epoch(&admin, &group).await == source + 2 && reads(&peer, &sealed).await,
            "the removal behind the flood was not applied, or the circle cannot read this \
             device afterwards",
        );
        assert!(
            kept(&admin, &group).is_empty() && unread(&admin, &group).is_empty(),
            "something of the flood is still kept, or the circle is still told it holds \
             unread input: an outsider keeps a note standing for as long as it likes",
        );
        let mut owed = admin.session().refused_redeliveries(&group, usize::MAX);
        let mut refused: Vec<nostr::EventId> = forged.iter().map(|event| event.id).collect();
        owed.sort_unstable();
        refused.sort_unstable();
        assert!(
            owed == refused,
            "an event the engine had no room for was not left owed its refetch by id",
        );
    }
}

/// Events the engine errs on AFTER writing its own record of them end where
/// they are handed back: they are the engine's from then on, a redelivery of
/// one is a duplicate to it, and nothing of them is kept.
///
/// Anyone who holds one of the circle's epoch keys can send such events
/// without number — here a member removed while this device's own commit was
/// pending, who goes on sealing at the epoch it still holds the key of, past
/// where any receiver's ratchet for it reaches: `OpenMLS` refuses a generation
/// more than a thousand ahead (`openmls/src/tree/sender_ratchet.rs`
/// 283-287, at MDK's `maximum_forward_distance`), and MDK stores the row and
/// its processed id and only then answers with an error (v0.10.4
/// `cgka-engine/src/message_processor/ingest.rs` 1206-1219, 1345-1347).
/// Three hundred of them are parked ahead of the removal: more than a
/// circle may keep. Kept as events the engine was asked for and would not
/// take, the first 256 would fill the cap and hold the circle — every seal,
/// every ingest, every change — until the next open, with the removal that
/// ends their sender's epoch stranded behind them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removed_members_messages_the_engine_errs_on_fill_nothing_and_the_removal_behind_them_is_handed_back(
) {
    const UNSEEN: usize = 1_002;
    const SENT: usize = KEPT_EVENTS_PER_CIRCLE + 44;
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let removed = others.remove(1);
    let peer = others.remove(0);
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    for member in [&peer, &removed] {
        member
            .session()
            .process_event_settled_for_test(&mine)
            .await
            .expect("the circle applies this device's commit");
    }
    let removal = peer
        .session()
        .remove_members(&group, &[removed.pubkey_hex()])
        .await
        .expect("the co-admin removes the third member");
    let (theirs, their_pending) = staged(&removal);
    peer.session()
        .confirm_published(their_pending)
        .await
        .expect("and confirms it");
    // The removed member is handed nothing more, and seals on.
    for _ in 0..UNSEEN {
        let _ = sealed_by(&removed, &group, 1.0).await;
    }
    for index in 0..SENT {
        let sent = sealed_by(&removed, &group, latitude_of(index)).await;
        assert!(
            parks(admin.session(), &sent).await,
            "premise: parked unread"
        );
    }
    assert!(
        parks(admin.session(), &theirs).await,
        "premise: parked unread"
    );
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    assert_eq!(stranded(&admin, &group).await, SENT + 1, "premise");

    // No look in between — no open, no confirm: a call's room at a time.
    for call in 1..=(SENT + 1).div_ceil(HAND_BACK_WHOLE) {
        let answered = admin.session().advance_for_receive(&group).await;
        let left = (SENT + 1).saturating_sub(call * HAND_BACK_WHOLE);
        assert!(
            kept(&admin, &group).is_empty() && stranded(&admin, &group).await == left,
            "an event the engine wrote its own record of and then erred on was kept, or the \
             call took over less than its room",
        );
        assert!(
            answered.is_ok() == (left == 0),
            "a call was answered held with nothing left to hand back, or went ahead of rows \
             its circle was still owed",
        );
    }
    let _ = served(admin.session(), &group).await;
    assert!(
        epoch(&admin, &group).await == source + 2
            && !roster(&admin, &group).await.contains(&removed.pubkey_hex())
            && unread(&admin, &group).is_empty(),
        "the removal behind the removed member's own events was not handed back and applied, \
         or its circle is still told it holds unread input",
    );
    let sealed = seal_or_deferral(&admin, &group, 44.0)
        .await
        .expect("nothing holds the circle's sends");
    assert!(
        reads(&peer, &sealed).await && !reads(&removed, &sealed).await,
        "the circle cannot read this device afterwards, or the removed member can",
    );
}

/// Past the cap nothing more of a circle is taken over, and its calls wait
/// for the room: held, typed, with the circle told and nothing sealed —
/// nothing new of the circle goes ahead of rows that can still be handed
/// back.
///
/// What fills the cap is the one thing that can: events the engine erred on
/// and kept NO record of — its own store failing under it — of which Haven's
/// copy is then the only one. While the cap is full each call asks the
/// engine for them again, so the call after the store recovers ends them,
/// and the one after that takes the rows.
#[tokio::test]
async fn past_the_cap_nothing_more_is_taken_over_and_the_circles_calls_wait() {
    const BEYOND: usize = 2;
    const SENT: usize = KEPT_EVENTS_PER_CIRCLE + BEYOND;
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    // Each within what a latitude may be, and its own.
    #[allow(clippy::cast_precision_loss)]
    let at = |index: usize| (index as f64).mul_add(0.125, 10.0);
    for index in 0..SENT {
        let fix = sealed_by(&others[0], &group, at(index)).await;
        assert!(parks(admin.session(), &fix).await, "premise: parked unread");
    }
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    let (db, key) = mls_db(admin.dir.path());

    set_new_stored_message_fault_for_test(&db, &key, true).expect("arm");
    for _ in 0..2 {
        let held_back = admin.session().advance_for_receive(&group).await;
        assert!(
            matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
                && all_parked_at(&held(admin.session(), &group).await, BEYOND, source)
                && kept(&admin, &group) == vec![true; KEPT_EVENTS_PER_CIRCLE]
                && unread(&admin, &group) == [ChangeNote::UnreadLocation],
            "a call went ahead of rows its circle could still be handed back, or a row was \
             taken over or dropped past the cap, or the circle is no longer told",
        );
        assert!(
            seal_or_deferral(&admin, &group, 41.0).await.is_none(),
            "a location was sealed while its circle held rows that could still be handed back",
        );
    }
    set_new_stored_message_fault_for_test(&db, &key, false).expect("disarm");

    // No open, no confirm, no new epoch in between: the call itself asks.
    let held_back = admin.session().advance_for_receive(&group).await;
    assert!(
        matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
            && kept(&admin, &group).is_empty()
            && stranded(&admin, &group).await == BEYOND,
        "with the cap full, what the engine had erred on was not asked for again by the next \
         call: nothing but a restart would ever have ended the hold",
    );
    let advanced = fixes(
        &admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs once the cap has room"),
    );
    assert!(
        advanced.len() == SENT
            && (0..SENT).all(|index| has_fix(&advanced[index..=index], &others[0], at(index)))
            && stranded(&admin, &group).await == 0
            && unread(&admin, &group).is_empty(),
        "what filled the cap and the rows it had held back did not all come back, once each \
         and in the order they arrived",
    );
}

/// The cap — on what is kept in bytes as well as in entries — stops the
/// taking over of rows and nothing else: what Haven keeps is still gone
/// through in that call, behind the rows it could not take. An entry the
/// engine now takes ends; one that is no longer an event at all — which only
/// a damaged store produces — ends too, its id owed its refetch, because
/// nothing can ever hand it back. So the call that finds the cap full makes
/// the room the next call takes rows into. A stop that ended the call there
/// would leave the cap full for good.
#[tokio::test]
async fn a_stop_at_the_cap_does_not_keep_what_the_engine_erred_on_from_being_tried() {
    use nostr::JsonUtil as _;

    let (admin, others, group, source, parked) = fixes_stranded_by_a_confirm(3).await;
    let damaged = [0x5a_u8; 32];
    let keep = |seq: i64, id: &[u8], event: String| {
        circle_store(&admin)
            .execute(
                "INSERT INTO kept_input (event_id, mls_group_id, seq, change, asked, event)
                 VALUES (?1, ?2, ?3, 0, 1, ?4)",
                rusqlite::params![id, group.as_slice(), seq, event],
            )
            .expect("a kept entry the engine was asked for");
    };
    // As large as the cap, and no event: it can never be handed back.
    keep(1, &damaged, "x".repeat(KEPT_BYTES_PER_CIRCLE));
    // The first stranded fix, which the engine erred on at an earlier look.
    keep(2, parked[0].id.as_bytes().as_slice(), parked[0].as_json());
    let admin = admin.reopen();

    let held_back = admin.session().advance_for_receive(&group).await;
    assert!(
        matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
            && all_parked_at(&held(admin.session(), &group).await, 2, source),
        "a row was taken over past the cap in bytes, or the call went ahead of the rows it \
         could not take",
    );
    assert!(
        kept(&admin, &group).is_empty(),
        "the stop at the cap ended the call ahead of an entry the engine would now take, or \
         an entry that is no event went on filling the cap",
    );
    // `assert!`, not `assert_eq!`: an id is never formatted (Security Rule 15).
    assert!(
        admin.session().refused_redeliveries(&group, 8)
            == [nostr::EventId::from_byte_array(damaged)],
        "an entry that could be handed back to nobody ended without its id being owed a refetch",
    );

    let advanced = fixes(
        &admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs once the cap has room"),
    );
    assert!(
        (0..3).all(|index| has_fix(&advanced, &others[index % others.len()], latitude_of(index)))
            && advanced.len() == 3
            && stranded(&admin, &group).await == 0
            && unread(&admin, &group).is_empty(),
        "what the call at the cap had been handed, or the rows it held back, did not come \
         back with the next call",
    );
}

/// A commit that removes THIS device is handed back like any other, and is
/// applied: a co-admin removed this device while a commit of its own was
/// pending, and then sealed a fix for the circle it left behind; both were
/// parked, and a kill stranded them. Afterwards nothing of a circle this
/// device is out of is kept, and nothing says it holds unread input.
///
/// What this does NOT show is the hand-back stopping BETWEEN two events of
/// one call because the first ended the circle: the engine applies a commit
/// it was handed in a pass of its own, a deadline later, so within one call
/// the circle's state has not yet changed when the next event is read. That
/// re-read is held by its text
/// (`the_second_connection_releases_a_row_only_in_the_hand_back_with_the_engine_held`);
/// the engine's clock is not Haven's to set
/// (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_handed_back_removal_of_this_device_is_applied_and_nothing_of_its_circle_is_kept() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let third = others.remove(1);
    let peer = others.remove(0);
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    for member in [&peer, &third] {
        member
            .session()
            .process_event_settled_for_test(&mine)
            .await
            .expect("the circle applies this device's commit");
    }
    let removal = peer
        .session()
        .remove_members(&group, &[admin.pubkey_hex()])
        .await
        .expect("the co-admin removes this device");
    let (theirs, their_pending) = staged(&removal);
    peer.session()
        .confirm_published(their_pending)
        .await
        .expect("and confirms it");
    let after = sealed_by(&peer, &group, 9.5).await;
    for event in [&theirs, &after] {
        assert!(
            parks(admin.session(), event).await,
            "premise: parked unread"
        );
    }
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    assert_eq!(stranded(&admin, &group).await, 2, "premise");

    // The removal is applied by the engine's own pass, a moment after it is
    // handed back: each call hands back what its circle still allows.
    for _ in 0..8 {
        let _ = admin.session().advance_for_receive(&group).await;
        let _ = served(admin.session(), &group).await;
        if !roster(&admin, &group).await.contains(&admin.pubkey_hex()) {
            break;
        }
    }
    assert!(
        !roster(&admin, &group).await.contains(&admin.pubkey_hex()),
        "premise: the removal of this device was handed back and applied",
    );
    let _ = admin.session().advance_for_receive(&group).await;
    assert!(
        kept(&admin, &group).is_empty()
            && stranded(&admin, &group).await == 0
            && unread(&admin, &group).is_empty(),
        "something of a circle this device was removed from is still kept or parked, or its \
         circle is still told of input nothing will hand back",
    );
}

/// A store that cannot say what stands is answered for as holding. Each of
/// these is a read or a write the hand-back makes before it has taken
/// anything over; failed, it leaves rows nobody looked at, and a call that
/// went on regardless would seal for the epoch the device is still at with
/// its circle neither told nor held. So the call waits — typed, the circle
/// still told, nothing sealed, nothing taken over or lost — and the call
/// after the store recovers hands everything back, in the order it arrived.
///
/// The faults are injected (`StoreFault`, compiled under `test-utils`
/// only): the engine's store and Haven's are real ones, and neither refuses
/// one read on demand.
#[tokio::test]
async fn a_hand_back_whose_store_cannot_say_what_stands_holds_its_circle_and_loses_nothing() {
    for fault in [
        StoreFault::Group,
        StoreFault::Kept,
        StoreFault::Rows,
        StoreFault::Keep,
    ] {
        let (admin, others, group, source, _) = fixes_stranded_by_a_confirm(2).await;
        let admin = admin.reopen();
        admin.session().fail_store_for_test(fault, true);
        for _ in 0..2 {
            let held_back = admin.session().advance_for_receive(&group).await;
            assert!(
                matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld)),
                "a call went ahead of rows a failing store kept it from looking at ({fault:?})",
            );
            assert!(
                all_parked_at(&held(admin.session(), &group).await, 2, source)
                    && kept(&admin, &group).is_empty()
                    && unread(&admin, &group) == [ChangeNote::UnreadLocation],
                "a row was taken over or lost behind a failing store, or its circle is no \
                 longer told ({fault:?})",
            );
            assert!(
                seal_or_deferral(&admin, &group, 42.0).await.is_none(),
                "a location was sealed ahead of rows a failing store kept from being handed \
                 back ({fault:?})",
            );
        }
        admin.session().fail_store_for_test(fault, false);
        let advanced = admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs once the store answers");
        assert!(
            in_arrival_order(&fixes(&advanced), &others)
                && stranded(&admin, &group).await == 0
                && unread(&admin, &group).is_empty(),
            "what a failing store had held back was not handed back, in order, once it \
             answered ({fault:?})",
        );
    }
}

/// An event the engine has no room for ends only once its id is on record
/// as owed its refetch. While that write fails, Haven's copy is the only
/// one there is — the engine's row was released, and the engine kept
/// nothing of what it refused — so it stays, asked for, and the next look
/// hands it back again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_event_whose_refetch_cannot_be_recorded_is_kept_until_it_can() {
    let (admin, _peer, group, _source, _removal) =
        a_fix_from_an_epoch_not_reached_stranded(true).await;
    let admin = admin.reopen();
    admin
        .session()
        .fail_store_for_test(StoreFault::Ledger, true);
    let _ = admin.session().advance_for_receive(&group).await;
    assert!(
        kept(&admin, &group) == [true]
            && stranded(&admin, &group).await == 0
            && admin.session().refused_redeliveries(&group, 16).is_empty(),
        "an event the engine refused ended with its refetch on record nowhere: it is in \
         neither store",
    );

    let admin = admin.reopen();
    let _ = admin.session().advance_for_receive(&group).await;
    assert!(
        kept(&admin, &group).is_empty()
            && admin.session().refused_redeliveries(&group, 16).len() == 1,
        "an event kept because its refetch could not be recorded was not handed back and \
         owed its refetch once the ledger took the write",
    );
}

/// A call for one circle that hands back another circle's stranded fix
/// folds that fix under its OWN circle: the bus names it by that circle, and
/// that circle's last-known row carries the time its sender put inside it.
#[tokio::test]
async fn a_fix_handed_back_in_a_call_for_another_circle_is_recorded_under_its_own() {
    let mut admin = CircleMember::new();
    let peers = [CircleMember::new(), CircleMember::new()];
    let asked = found_circle(&admin, &[&peers[0]], &[ONE]).await;
    let other = found_circle(&admin, &[&peers[1]], &[ONE]).await;
    let source = epoch(&admin, &other).await;
    let taken_at = chrono::Utc::now() - chrono::Duration::seconds(90);
    let (_, pending) = stage_relays(admin.session(), &other, &[ONE, TWO]).await;
    let fix = sealed_at(&peers[1], &other, 48.25, taken_at).await;
    assert!(parks(admin.session(), &fix).await, "premise: parked unread");
    admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    let (asked_id, other_id) = (ngid(&admin, &asked).await, ngid(&admin, &other).await);

    let bus = EventBus::new();
    let mut carried = bus.subscribe();
    let processor = EngineProcessor::new(std::sync::Arc::clone(&admin.circle), bus);
    let trigger = sealed_by(&peers[0], &asked, 10.5).await;
    assert_eq!(
        processor.process_group_event(&trigger, &asked_id).await,
        GroupProcessOutcome::Applied,
        "premise: the call's own event is applied",
    );
    let mut named = Vec::new();
    while let Ok(event) = carried.try_recv() {
        if let LiveSyncEvent::Location {
            nostr_group_id,
            sender_pubkey,
            ..
        } = event
        {
            named.push((nostr_group_id, sender_pubkey));
        }
    }
    assert!(
        named.len() == 2
            && named.contains(&(other_id.to_vec(), peers[1].pubkey_hex()))
            && named.contains(&(asked_id.to_vec(), peers[0].pubkey_hex())),
        "a fix handed back in a call for another circle was not carried under its own circle",
    );
    let rows = |circle: &[u8; 32]| -> Vec<(String, f64, i64)> {
        admin
            .circle
            .snapshot_last_known_for_circle(circle, chrono::Utc::now().timestamp())
            .expect("the store is read")
            .into_iter()
            .map(|row| (row.sender_pubkey, row.latitude, row.timestamp))
            .collect()
    };
    let (theirs, asked_rows) = (rows(&other_id), rows(&asked_id));
    assert!(
        theirs.len() == 1
            && theirs[0].0 == peers[1].pubkey_hex()
            && (theirs[0].1 - 48.25).abs() < 1e-9
            && theirs[0].2 == taken_at.timestamp()
            && asked_rows.iter().all(|row| row.0 == peers[0].pubkey_hex()),
        "a fix handed back in a call for another circle was stored under the wrong circle, or \
         with a time other than its sender's",
    );
}

/// What a replay error leaves parked in a RUNNING process is told the moment
/// the confirm returns — no open in between — and handed back ahead of the
/// next event that circle is delivered, through the same fold: the fix is in
/// what the ingest hands back, before the new one. The engine keeps nothing
/// of a released row in memory.
#[tokio::test]
async fn what_a_replay_error_leaves_parked_is_told_at_once_and_handed_back_by_the_next_ingest() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let (db, key) = mls_db(admin.dir.path());
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let struck = sealed_by(&others[0], &group, 48.25).await;
    let behind = sealed_by(&others[1], &group, 48.5).await;
    for fix in [&struck, &behind] {
        assert!(parks(admin.session(), fix).await, "premise: parked unread");
    }
    set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), true)
        .expect("arm");
    let confirmed = admin.session().confirm_published(pending).await;
    set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), false)
        .expect("disarm");
    assert!(confirmed.is_err(), "premise: the replay ended on an error");
    assert_eq!(
        unread(&admin, &group),
        [ChangeNote::UnreadLocation],
        "what a failed replay left parked was not told when the confirm returned",
    );

    let next = sealed_by(&others[1], &group, 49.75).await;
    let delivered = admin
        .circle
        .ingest_for_test(&next)
        .await
        .expect("the next event is ingested");
    let handed_back = delivered
        .iter()
        .position(|result| has_fix(std::slice::from_ref(result), &others[1], 48.5));
    let new = delivered
        .iter()
        .position(|result| has_fix(std::slice::from_ref(result), &others[1], 49.75));
    assert!(
        handed_back.is_some() && handed_back < new,
        "the fix a replay error left parked was not handed back ahead of the next event",
    );
    assert!(
        unread(&admin, &group).is_empty() && kept(&admin, &group).is_empty(),
        "after the hand-back the note still stands, or a copy is still kept",
    );
}

/// A circle told it holds stranded input is told it no longer does when the
/// engine's own replay drains it: this device's next rollback. Only where
/// Haven could not hand the row back first — here a session with no store
/// to keep an event in, which takes nothing over and holds nothing up, so a
/// change is staged over the row; every other row is handed back before a
/// commit is staged over it.
#[tokio::test]
async fn a_note_ends_when_the_engines_own_replay_drains_what_was_stranded() {
    let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(1).await;
    let peer = &others[0];
    let engine = bare(admin);
    let unread = || {
        let mut notes = engine.session.peek_change_notes(&group);
        notes.retain(|note| matches!(note, ChangeNote::UnreadChange | ChangeNote::UnreadLocation));
        notes
    };
    assert_eq!(unread(), [ChangeNote::UnreadLocation]);
    // Shown to its user, and acknowledged: it says what IS, so it stands.
    engine
        .session
        .acknowledge_change_notice(&group, &engine.session.change_notice(&group));
    assert_eq!(
        unread(),
        [ChangeNote::UnreadLocation],
        "a circle that still holds unread input was told nothing once the note was shown",
    );
    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
    assert_eq!(
        unopened_retryable(&held(&engine.session, &group).await),
        1,
        "premise: the row stands behind the change staged over it",
    );
    let rolled = engine
        .session
        .publish_failed(pending)
        .await
        .expect("a rollback of this device's own");
    assert!(
        has_fix(&fixes(&rolled), peer, latitude_of(0)) && unread().is_empty(),
        "the engine's replay drained the row and the circle is still told it is unread",
    );
}

// ── A death at any point ─────────────────────────────────────────────────────

/// The hand-back of one event has three points a process can die at: the
/// event kept and the engine's row still there; the row released and the
/// event not yet handed back; the engine's answer in and the kept copy not
/// yet ended. Each is died at — for the first event, and for a later one —
/// and the next process delivers all three stranded fixes once each, in the
/// order they arrived, counting what the engine itself hands back at an
/// open. While anything is still owed the circle stays told.
#[tokio::test]
async fn a_death_at_any_point_of_a_hand_back_loses_nothing_repeats_nothing_and_keeps_the_order() {
    for (point, after) in [
        (HandBackStop::Kept, 0),
        (HandBackStop::Released, 0),
        (HandBackStop::Released, 1),
        (HandBackStop::Ingested, 0),
        (HandBackStop::Ingested, 2),
    ] {
        let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(3).await;
        let admin = admin.reopen();
        admin.session().stop_hand_back_for_test(point, after);
        let dying = admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs");
        assert!(
            fixes(&dying).is_empty(),
            "premise: a process that died mid hand-back handed nothing on ({point:?}, {after})",
        );

        let admin = admin.reopen();
        assert_eq!(
            unread(&admin, &group),
            [ChangeNote::UnreadLocation],
            "a circle still owed a hand-back is no longer told ({point:?}, {after})",
        );
        let mut delivered = fixes(&admin.session().drain().await);
        let advanced = admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs");
        delivered.extend(fixes(&advanced));
        assert!(
            in_arrival_order(&delivered, &others),
            "a death at {point:?} after {after} lost a stranded fix, delivered one twice, or \
             changed their order",
        );
        assert!(
            stranded(&admin, &group).await == 0
                && kept(&admin, &group).is_empty()
                && unread(&admin, &group).is_empty(),
            "after the resumed hand-back something is still parked, kept or noted \
             ({point:?}, {after})",
        );
    }
}

// ── What cannot be handed back ───────────────────────────────────────────────

/// A kept copy that is no longer an event can be handed back to nobody, and
/// does not stay to be counted against its circle for good: with the
/// engine's row for it already released the event is in neither store, so
/// its id is owed its refetch — durably, as one the engine refused is — and
/// the entry ends. It holds up nothing behind it: the other stranded fixes
/// are delivered at the first hand-back, and the note ends with them.
#[tokio::test]
async fn a_kept_copy_that_is_no_longer_its_event_ends_owed_its_refetch_and_holds_up_nothing() {
    let (admin, others, group, _, parked) = fixes_stranded_by_a_confirm(3).await;
    let admin = admin.reopen();
    admin
        .session()
        .stop_hand_back_for_test(HandBackStop::Released, 0);
    let _ = admin.session().advance_for_receive(&group).await;
    assert_eq!(
        circle_store(&admin)
            .execute("UPDATE kept_input SET event = 'not an event'", [])
            .expect("the kept copy is damaged"),
        1,
        "premise: one event was kept and its row released",
    );

    let admin = admin.reopen();
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    let behind = fixes(&advanced);
    assert!(
        behind.len() == 2
            && has_fix(&behind[..1], &others[1], latitude_of(1))
            && has_fix(&behind[1..], &others[2], latitude_of(2)),
        "the fixes behind a kept copy that cannot be handed back were held up by it",
    );
    assert!(
        kept(&admin, &group).is_empty() && unread(&admin, &group).is_empty(),
        "a kept copy nothing can hand back went on being kept, or its circle is still told \
         of input that is no longer there",
    );
    let admin = admin.reopen();
    // `assert!`, not `assert_eq!`: an id is never formatted (Security Rule 15).
    assert!(
        admin.session().refused_redeliveries(&group, 8) == [parked[0].id],
        "the event of a kept copy that could not be handed back is owed no refetch: it is \
         in neither store, and nothing will bring it back",
    );
}

/// No count of epochs ends an event the engine erred on and kept no record
/// of. Haven's copy is then the only one, and how far its circle has moved
/// says nothing about whether the event can still be used: the circle here
/// moves further than the engine keeps anything for, and the entry stands —
/// kept, asked for again at each new epoch, its circle told — until the
/// engine takes it.
#[tokio::test]
async fn an_event_the_engine_erred_on_is_not_ended_by_a_count_of_epochs() {
    let (admin, _others, group, _, parked) = fixes_stranded_by_a_confirm(2).await;
    let admin = admin.reopen();
    let (db, key) = mls_db(admin.dir.path());
    let erred = parked[0].id.as_bytes();
    set_new_stored_message_fault_naming_for_test(&db, &key, erred, true).expect("arm");
    let _ = admin.session().advance_for_receive(&group).await;
    assert!(
        kept(&admin, &group) == [true] && stranded(&admin, &group).await == 0,
        "premise: the engine erred on one event, recording nothing of it, and took the other",
    );

    for step in 0..usize::try_from(max_rewind_commits()).expect("a small number") + 3 {
        let relays = if step % 2 == 0 {
            [ONE, THREE]
        } else {
            [ONE, TWO]
        };
        let (_, pending) = stage_relays(admin.session(), &group, &relays).await;
        admin
            .session()
            .confirm_published(pending)
            .await
            .expect("the device's own change is confirmed");
        let _ = admin.session().advance_for_receive(&group).await;
        assert!(
            kept(&admin, &group) == [true]
                && unread(&admin, &group) == [ChangeNote::UnreadLocation],
            "an event the engine erred on was ended by how far its circle had moved, or its \
             circle is no longer told",
        );
    }

    set_new_stored_message_fault_naming_for_test(&db, &key, erred, false).expect("disarm");
    let admin = admin.reopen();
    let _ = admin.session().advance_for_receive(&group).await;
    assert!(
        kept(&admin, &group).is_empty() && unread(&admin, &group).is_empty(),
        "an entry the engine has now answered for was not ended, or its note stands",
    );
}

/// A kept copy is read, verified and compared with the id its entry names
/// BEFORE the engine's row beside it is released: a copy damaged while that
/// row still stood costs nothing, because the event is still the engine's.
/// Released first, the event would be in neither store. The damaged copy
/// ends, its circle's call waits, and the next call takes the row over
/// afresh — in the place the event arrived in, ahead of the rows behind it.
#[tokio::test]
async fn a_damaged_kept_copy_never_costs_the_engines_row_beside_it() {
    let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(3).await;
    let admin = admin.reopen();
    admin
        .session()
        .stop_hand_back_for_test(HandBackStop::Kept, 0);
    let _ = admin.session().advance_for_receive(&group).await;
    assert_eq!(
        circle_store(&admin)
            .execute("UPDATE kept_input SET event = 'not an event'", [])
            .expect("the kept copy is damaged"),
        1,
        "premise: one event was kept, and its row is still the engine's",
    );

    let admin = admin.reopen();
    let held_back = admin.session().advance_for_receive(&group).await;
    assert!(
        matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
            && stranded(&admin, &group).await == 3
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "the engine's row was released beside a kept copy that is no longer its event, a row \
         behind it was taken ahead of it, or the damaged copy went on being kept",
    );
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        in_arrival_order(&fixes(&advanced), &others)
            && stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "the row a damaged copy stood beside was not taken over afresh and handed back in \
         its place",
    );
}

/// Haven hands the engine nothing whose id and signature it has not itself
/// verified (Security Rule 16), whatever the engine's own peel would then
/// make of it. A stranded row whose event's signature does not verify —
/// which only a damaged store can produce — is not released and is told of
/// as a change, and the row behind it is handed back all the same.
#[tokio::test]
async fn a_stranded_row_whose_event_does_not_verify_is_not_released_and_stays_told() {
    let (admin, others, group, _, parked) = fixes_stranded_by_a_confirm(2).await;
    let (db, key) = mls_db(admin.dir.path());
    assert!(
        forge_stored_event_signature_for_test(&db, &key, parked[0].id.as_bytes()).expect("forge"),
        "premise: the stored row keeps its event's signature",
    );
    let admin = admin.reopen();
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    let delivered = fixes(&advanced);
    assert!(
        !has_fix(&delivered, &others[0], latitude_of(0))
            && has_fix(&delivered, &others[1], latitude_of(1))
            && stranded(&admin, &group).await == 1
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "a stored row whose event does not verify was released or handed to the engine, held \
         up the row behind it, or left its circle untold",
    );
}

/// The same for a copy Haven kept: read back with a signature that does not
/// verify, it is handed to nobody and holds up nothing behind it. With the
/// engine's row already released it ends, its id owed its refetch: a relay's
/// copy of the event is verified like any other.
#[tokio::test]
async fn a_kept_copy_whose_signature_does_not_verify_is_handed_to_nobody() {
    let (admin, others, group, _, parked) = fixes_stranded_by_a_confirm(3).await;
    let admin = admin.reopen();
    admin
        .session()
        .stop_hand_back_for_test(HandBackStop::Released, 0);
    let _ = admin.session().advance_for_receive(&group).await;
    let store = circle_store(&admin);
    let event: String = store
        .query_row("SELECT event FROM kept_input", [], |kept| kept.get(0))
        .expect("premise: one event was kept and its row released");
    let at = event.find("\"sig\":\"").expect("a signed event") + "\"sig\":\"".len();
    let forged = format!(
        "{}{}{}",
        &event[..at],
        if event[at..].starts_with('0') {
            '1'
        } else {
            '0'
        },
        &event[at + 1..],
    );
    assert_eq!(
        store
            .execute("UPDATE kept_input SET event = ?1", [forged])
            .expect("the kept copy is forged"),
        1,
    );
    drop(store);

    let admin = admin.reopen();
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    let delivered = fixes(&advanced);
    assert!(
        !has_fix(&delivered, &others[0], latitude_of(0))
            && has_fix(&delivered, &others[1], latitude_of(1))
            && has_fix(&delivered, &others[2], latitude_of(2))
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "a kept copy whose signature does not verify was handed to the engine, held up the \
         events behind it, or went on being kept",
    );
    // `assert!`, not `assert_eq!`: an id is never formatted (Security Rule 15).
    assert!(
        admin.session().refused_redeliveries(&group, 8) == [parked[0].id],
        "the event of a kept copy that does not verify is owed no refetch",
    );
}

/// An event the engine errs on is kept and handed back again; nothing is
/// lost to an error, and the order of what the engine did take is the order
/// it arrived in.
#[tokio::test]
async fn an_event_the_engine_errs_on_is_kept_and_handed_back_again() {
    let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(2).await;
    let admin = admin.reopen();
    let (db, key) = mls_db(admin.dir.path());
    set_new_stored_message_fault_for_test(&db, &key, true).expect("arm");
    let failed = admin.session().advance_for_receive(&group).await;
    set_new_stored_message_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        failed.map_or(true, |effects| fixes(&effects).is_empty())
            && stranded(&admin, &group).await == 0
            && kept(&admin, &group) == [true, true]
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "events the engine erred on are not both kept, with their circle still told",
    );

    // Told again where it stands: the next look is the next open.
    let admin = admin.reopen();
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        in_arrival_order(&fixes(&advanced), &others)
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "events kept through an engine error were not handed back, in order, afterwards",
    );
}

/// An event Haven cannot keep is not released: the engine's row is the only
/// copy. While the circle's store refuses the write, the circle's calls
/// wait: a redelivery of the event is not taken — the engine is not asked,
/// and the caller holds its cursor — nothing is lost, and the circle stays
/// told. Once it can be kept, the next delivery of it hands it back, and
/// that delivery is a duplicate.
#[tokio::test]
async fn an_event_that_cannot_be_kept_is_not_released_and_its_circles_calls_wait_until_it_can() {
    let (admin, others, group, source, parked) = fixes_stranded_by_a_rollback(2).await;
    let admin = admin.reopen();
    circle_store(&admin)
        .execute_batch(NOTHING_CAN_BE_KEPT)
        .expect("arm");
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let poll = through(&transport, &outbox, &clock, &FULL);

    let polled = poll.ingest_for_poll(&admin.circle, &parked[0]).await;
    assert!(
        matches!(polled, Err(haven_core::circle::CircleError::EngineHeld)),
        "a delivery for a circle whose stranded rows could not be kept was taken ahead of \
         them, or was answered as anything but held",
    );
    assert!(
        all_parked_at(&held(admin.session(), &group).await, 2, source)
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "an event that could not be kept was released, or its circle is no longer told",
    );

    circle_store(&admin)
        .execute_batch("DROP TRIGGER kept_input_fault;")
        .expect("disarm");
    let polled = poll
        .ingest_for_poll(&admin.circle, &parked[0])
        .await
        .expect("the redelivery is ingested");
    assert_eq!(polled.verdict, ReceiveOnlyOutcome::Applied);
    assert!(
        has_fix(&polled.replayed, &others[0], latitude_of(0))
            && has_fix(&polled.replayed, &others[1], latitude_of(1))
            && stranded(&admin, &group).await == 0
            && unread(&admin, &group).is_empty(),
        "a redelivered stranded event was not handed back with what was stranded beside it",
    );
    assert!(
        transport.calls().is_empty() && outbox.handed().is_empty(),
        "handing stranded input back called a relay or published something",
    );
}

/// A release the engine's store refuses — MDK's fails when its receipt
/// journal is full, or when the store errs — leaves the event where it was:
/// the engine's row stands, no copy is kept beside it and nothing is
/// delivered. The call is answered held, its circle stays told, and nothing
/// new of the circle goes ahead of the row. The next call asks the store
/// again, and once it takes the release everything is handed back, in order.
#[tokio::test]
async fn a_release_the_engines_store_refuses_holds_the_circle_until_the_store_takes_it() {
    let (admin, others, group, source, _) = fixes_stranded_by_a_confirm(2).await;
    let (db, key) = mls_db(admin.dir.path());
    let admin = admin.reopen();
    set_stored_message_delete_fault_for_test(&db, &key, true).expect("arm");
    for call in 0..2 {
        let held_back = admin.session().advance_for_receive(&group).await;
        assert!(
            matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
                && all_parked_at(&held(admin.session(), &group).await, 2, source)
                && kept(&admin, &group).is_empty()
                && unread(&admin, &group) == [ChangeNote::UnreadLocation],
            "a release the store refused lost the engine's row, left a copy beside it, let \
             the call go ahead of it, or left the circle untold (call {call})",
        );
    }
    assert!(
        seal_or_deferral(&admin, &group, 42.0).await.is_none(),
        "a location was sealed ahead of a row the store had refused to release",
    );
    set_stored_message_delete_fault_for_test(&db, &key, false).expect("disarm");

    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        in_arrival_order(&fixes(&advanced), &others)
            && stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "what a refused release left with the engine was not handed back by the next call \
         once the store took the release",
    );
}

/// The same where Haven already keeps the event and the engine's row still
/// stands beside the copy — a death between the two: the release is asked of
/// the store again, a refusal holds the circle with both left as they are,
/// and once the store takes it the event is handed back with the rest.
#[tokio::test]
async fn a_release_refused_beside_a_kept_copy_holds_the_circle_until_the_store_takes_it() {
    let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(2).await;
    let (db, key) = mls_db(admin.dir.path());
    let admin = admin.reopen();
    admin
        .session()
        .stop_hand_back_for_test(HandBackStop::Kept, 0);
    let _ = admin.session().advance_for_receive(&group).await;
    let admin = admin.reopen();
    assert!(
        kept(&admin, &group) == [false] && stranded(&admin, &group).await == 2,
        "premise: one event is kept, and its row is still the engine's",
    );

    set_stored_message_delete_fault_for_test(&db, &key, true).expect("arm");
    let held_back = admin.session().advance_for_receive(&group).await;
    assert!(
        matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
            && stranded(&admin, &group).await == 2
            && kept(&admin, &group) == [false]
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "a release the store refused beside a kept copy let the call go ahead, lost the \
         row or the copy, or left the circle untold",
    );
    set_stored_message_delete_fault_for_test(&db, &key, false).expect("disarm");

    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        in_arrival_order(&fixes(&advanced), &others)
            && stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "what a refused release left was not handed back once the store took the release",
    );
}

/// What makes Haven unable to keep an event, for a test of what a redelivery
/// of a stranded event is then answered.
const NOTHING_CAN_BE_KEPT: &str = "CREATE TRIGGER kept_input_fault BEFORE INSERT ON kept_input
     BEGIN SELECT RAISE(ABORT, 'injected'); END;";

/// The live plane's own arm has the cursor rule too: a stranded event that a
/// subscription delivers again — here one a rollback left under the epoch
/// its circle is STILL at, which the arm below it would hold — is reported
/// stranded, and its circle is told. The row is one Haven can hand back to
/// nobody, and so holds nothing: its stored copy no longer verifies.
#[tokio::test]
async fn a_stranded_events_redelivery_on_the_live_plane_is_reported_stranded_not_held() {
    let (admin, _, group, source, parked) = fixes_stranded_by_a_rollback(1).await;
    let (db, key) = mls_db(admin.dir.path());
    assert!(
        forge_stored_event_signature_for_test(&db, &key, parked[0].id.as_bytes()).expect("forge"),
        "premise: the stored row keeps its event's signature",
    );
    let admin = admin.reopen();
    let routing = ngid(&admin, &group).await;
    let processor = EngineProcessor::new(std::sync::Arc::clone(&admin.circle), EventBus::new());

    assert_eq!(
        processor.process_group_event(&parked[0], &routing).await,
        GroupProcessOutcome::Stranded,
        "the live plane reads a stranded event's redelivery as buffered, and would hold \
         its anchor at it for as long as a relay serves it",
    );
    assert!(
        all_parked_at(&held(admin.session(), &group).await, 1, source)
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "premise: the event could not be taken over, and its circle is told",
    );
}

/// And the catch-up sweep, through the one classifier: a stranded event a
/// relay serves again is tallied as stranded — neither applied nor deferred —
/// and the sweep's cursor moves on from where it stood.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stranded_event_a_relay_serves_again_is_tallied_stranded_by_the_sweep() {
    let _ = allow_ws_loopback_for_test();
    let relay = nostr_relay_builder::MockRelay::run()
        .await
        .expect("an in-process relay");
    let url = relay.url().await.to_string();
    let relays = RelayManager::new();
    let (admin, _, group, source, parked) = fixes_stranded_by_a_rollback_on(&url, 1).await;
    relays
        .publish_event(&parked[0], std::slice::from_ref(&url))
        .await
        .expect("the relay holds the event");
    // A row Haven can hand back to nobody, and that so holds nothing.
    let (db, key) = mls_db(admin.dir.path());
    assert!(
        forge_stored_event_signature_for_test(&db, &key, parked[0].id.as_bytes()).expect("forge"),
        "premise: the stored row keeps its event's signature",
    );
    let admin = admin.reopen();
    let stream = group_cursor_stream(&hex::encode(ngid(&admin, &group).await));
    let floor = (i64::try_from(parked[0].created_at.as_secs()).expect("secs") - 7_200) * 1_000;
    admin
        .circle
        .advance_sync_cursor(&stream, floor)
        .expect("a cursor to move on from");

    let swept = run_catchup_all_circles(&admin.circle, &relays, 20).await;
    assert!(
        swept.events_stranded == 1 && swept.events_deferred == 0 && swept.events_applied == 0,
        "a stranded event a relay served again was not tallied as stranded",
    );
    assert!(
        admin
            .circle
            .read_sync_cursor(&stream)
            .expect("the cursor is read")
            .is_some_and(|cursor| cursor > floor)
            && all_parked_at(&held(admin.session(), &group).await, 1, source)
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "the sweep's cursor stayed where it stood, or the event was taken over, or its \
         circle is not told",
    );
}

/// The circle a call is for is handed back whole; every other circle shares
/// one bounded slice per call, and what that slice did not reach is seen to
/// at the next call, not left until the next look.
#[tokio::test]
async fn a_circle_the_slice_did_not_reach_is_handed_back_at_the_next_call() {
    const EACH: usize = 17;
    let mut admin = CircleMember::new();
    let peers = [CircleMember::new(), CircleMember::new()];
    let mut circles = Vec::new();
    for peer in &peers {
        circles.push(found_circle(&admin, &[peer], &[ONE]).await);
    }
    let mut pending = Vec::new();
    for (group, peer) in circles.iter().zip(&peers) {
        let source = epoch(&admin, group).await;
        let (_, staged) = stage_relays(admin.session(), group, &[ONE, TWO]).await;
        for index in 0..EACH {
            let fix = sealed_by(peer, group, latitude_of(index)).await;
            assert!(parks(admin.session(), &fix).await, "premise: parked unread");
        }
        pending.push((staged, source + 1));
    }
    for (staged, reached) in pending {
        admin = confirm_and_die(admin, staged, reached).await;
    }
    let admin = admin.reopen();

    let mut handed_back = Vec::new();
    for _ in 0..3 {
        let advanced = admin
            .session()
            .advance_for_receive(&circles[0])
            .await
            .expect("the advance runs");
        handed_back.push(fixes(&advanced).len());
    }
    assert_eq!(
        handed_back,
        [EACH + 16, 1, 0],
        "the circle the call was for was not handed back whole, or another circle got more \
         than its slice, or what the slice did not reach was not seen to at the next call",
    );
    for group in &circles {
        assert!(stranded(&admin, group).await == 0 && unread(&admin, group).is_empty());
    }
}

/// A stranded fix whose NIP-40 expiration has passed is handed back like any
/// other: the tag is unauthenticated, decides nothing about what Haven
/// keeps or destroys, and the engine reads none when it replays its own
/// rows. What the fix then looks like is the presentation's to say, from the
/// time its sender put inside it
/// (`a_handed_back_fix_never_displaces_a_newer_one_of_the_same_member`).
#[tokio::test]
async fn a_stranded_fix_past_its_expiration_is_handed_back_all_the_same() {
    let (admin, others, group, _, parked) = fixes_stranded_by_a_confirm(2).await;
    let admin = admin.reopen();
    let in_ten_minutes =
        u64::try_from(chrono::Utc::now().timestamp_millis()).expect("now") + 600_000;
    admin.session().set_legacy_clock_for_test(in_ten_minutes);
    assert!(
        parked.iter().all(|fix| fix
            .tags
            .expiration()
            .is_some_and(|at| at.as_secs() < in_ten_minutes / 1_000)),
        "premise: by this device's clock both fixes are past their expiration",
    );
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        in_arrival_order(&fixes(&advanced), &others),
        "a stranded fix was dropped for its expiration tag instead of being handed back",
    );
    assert!(
        stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "a handed-back fix is still parked, kept or noted",
    );
}

/// What the app shows of a member is that member's newest fix by the time
/// the SENDER put inside it, which the engine authenticated — never by when
/// this device was handed it. So a stranded fix handed back after a newer
/// one of the same member has arrived changes nothing of what is shown: the
/// row keeps the newer position and the newer fix's own time.
#[tokio::test]
async fn a_handed_back_fix_never_displaces_a_newer_one_of_the_same_member() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let peer = &others[0];
    let source = epoch(&admin, &group).await;
    let now = chrono::Utc::now();
    let older = sealed_at(peer, &group, 48.25, now - chrono::Duration::seconds(120)).await;
    let (commit, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    assert!(
        parks(admin.session(), &older).await,
        "premise: parked unread"
    );
    let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
    // The engine errs on the older fix — its store fails under it — so the
    // fix stays Haven's until the next look, and the newer one, sealed at
    // the epoch the circle has since reached, is read first.
    let (db, key) = mls_db(admin.dir.path());
    set_new_stored_message_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin.session().advance_for_receive(&group).await;
    set_new_stored_message_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        kept(&admin, &group) == [true],
        "premise: the older fix is kept"
    );
    let mine = ngid(&admin, &group).await;
    let newer_at = now - chrono::Duration::seconds(60);
    peer.session()
        .process_event_settled_for_test(&commit)
        .await
        .expect("the peer applies the device's commit");
    let newer = sealed_at(peer, &group, 49.5, newer_at).await;
    let first = admin
        .circle
        .ingest_for_test(&newer)
        .await
        .expect("the newer fix is ingested");
    assert!(
        has_fix(&first, peer, 49.5) && !has_fix(&first, peer, 48.25),
        "premise: the newer fix was read while the older one stood stranded",
    );
    let admin = admin.reopen();
    let late = admin
        .circle
        .ingest_for_test(&older)
        .await
        .expect("the redelivery is ingested");
    assert!(
        has_fix(&late, peer, 48.25),
        "premise: the stranded fix was handed back, after the newer one",
    );
    let shown: Vec<(f64, i64)> = admin
        .circle
        .snapshot_last_known_for_circle(&mine, chrono::Utc::now().timestamp())
        .expect("the store is read")
        .into_iter()
        .map(|row| (row.latitude, row.timestamp))
        .collect();
    assert!(
        shown.len() == 1 && (shown[0].0 - 49.5).abs() < 1e-9 && shown[0].1 == newer_at.timestamp(),
        "an older fix handed back displaced the member's newer one, or was given a time \
         other than its sender's",
    );
}

/// A stranded fix handed back after the circle has moved further than the
/// engine keeps epochs for cannot be opened. Whatever the engine makes of it
/// — a verdict, or a deferral — it is the engine's again: Haven keeps
/// nothing of it and tells the circle nothing more. Nothing is owed to a
/// relay for it either, until the engine itself lets it go, which is then
/// announced and refetched like any other object's
/// (`an_event_the_engine_lets_go_is_owed_its_refetch_whether_or_not_haven_handed_it_back`).
#[tokio::test]
async fn a_stranded_fix_older_than_the_engine_keeps_epochs_for_is_owed_to_no_relay() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let parked = sealed_by(&others[1], &group, 48.25).await;
    assert!(parks(admin.session(), &parked).await);
    let engine = bare(confirm_and_die(admin, pending, source + 1).await);
    others[0]
        .session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the co-admin applies the commit");
    for step in 0..=haven_core::nostr::mls::DEFAULT_MAX_PAST_EPOCHS {
        let relays = if step % 2 == 0 {
            [ONE, THREE]
        } else {
            [ONE, TWO]
        };
        let (commit, their_pending) = stage_relays(others[0].session(), &group, &relays).await;
        others[0]
            .session()
            .confirm_published(their_pending)
            .await
            .expect("the co-admin's change is confirmed");
        engine
            .session
            .process_event_settled_for_test(&commit)
            .await
            .expect("the device applies it");
    }
    assert!(
        engine.session.epoch(&group).await.expect("epoch") > source + 6
            && unopened_retryable(&held(&engine.session, &group).await) == 1,
        "premise: the circle moved past the engine's window with the fix still stranded",
    );

    let admin = engine.with_its_circle_store();
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        !has_fix(&fixes(&advanced), &others[1], 48.25),
        "premise: a fix sealed further back than the engine keeps epochs for was opened",
    );
    assert!(
        stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty()
            && admin.session().refused_redeliveries(&group, 16).is_empty()
            && admin.session().refused_range(&group).is_none(),
        "a stranded fix that can no longer be opened is still parked, kept, noted, or owed \
         to a relay before the engine has let it go",
    );
}

// ── No relay, in any lifecycle ───────────────────────────────────────────────

/// Handing stranded input back contacts no relay and publishes nothing, in
/// each disposition a receive plane ingests under: the foreground driver's,
/// and the finish-only one, which besides records nothing and stages
/// nothing. In each, what was stranded comes back in the same batch as the
/// event that brought it, ahead of it.
#[tokio::test]
async fn handing_stranded_input_back_calls_no_relay_in_any_lifecycle() {
    for mode in [FULL, FINISH_ONLY] {
        let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(1).await;
        let admin = admin.reopen();
        let next = sealed_by(&others[0], &group, 49.75).await;
        let transport = ScriptedFanout::default();
        transport.answer(ONE, [Answer::Accepted]);
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        let delivered = within(&transport, &outbox, &clock, &mode, 2 * ROW_BUDGET_MS)
            .ingest_for_poll(&admin.circle, &next)
            .await
            .expect("the poll runs")
            .replayed;
        assert!(
            has_fix(&delivered, &others[0], latitude_of(0))
                && has_fix(&delivered, &others[0], 49.75),
            "what was stranded did not come back with the event that brought it",
        );
        assert!(
            transport.calls().is_empty()
                && outbox.handed().is_empty()
                && records_of(&admin, &group).await.is_empty()
                && staged_ref(&admin, &group).await.is_none(),
            "handing stranded input back called a relay, published, recorded or staged \
             something",
        );
        assert!(unread(&admin, &group).is_empty() && clock.now_ms() == ManualClock::ORIGIN);
    }
}

/// Each engine entry a receive plane uses hands back first, by itself: the
/// plain ingest, the staging ingest and the driving advance are each asked
/// alone, with nothing else called before them, and each returns the
/// stranded fix ahead of its own. (The receive advance is asked alone in the
/// tests above; the finish-only advance is reachable only behind a staging
/// ingest, and is held by the source gate.)
#[tokio::test]
async fn each_engine_entry_a_receive_plane_uses_hands_stranded_input_back_by_itself() {
    use haven_core::nostr::mls::types::ScreenedIngest;

    for entry in ["ingest", "staging ingest", "driving advance"] {
        let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(1).await;
        let admin = admin.reopen();
        let next = sealed_by(&others[0], &group, 49.75).await;
        let now_ms = ManualClock::ORIGIN;
        let effects = match entry {
            "ingest" => match admin.session().process_event(&next).await {
                Ok(ScreenedIngest::Ingested(ingest)) => ingest.effects,
                _ => panic!("the ingest runs"),
            },
            "staging ingest" => match admin
                .session()
                .process_event_staging_for_test(&next, now_ms, &FULL)
                .await
            {
                Ok((ScreenedIngest::Ingested(ingest), _)) => ingest.effects,
                _ => panic!("the staging ingest runs"),
            },
            _ => {
                admin
                    .session()
                    .advance_for_drive(&group, now_ms)
                    .await
                    .expect("the driving advance runs")
                    .effects
            }
        };
        let delivered = fixes(&effects);
        assert!(
            !delivered.is_empty() && has_fix(&delivered[..1], &others[0], latitude_of(0)),
            "the {entry} did not hand the stranded fix back ahead of its own batch",
        );
        assert!(unread(&admin, &group).is_empty() && stranded(&admin, &group).await == 0);
    }
}

/// A stranded COMMIT handed back in the finish-only disposition is applied by
/// the inputs-only advance, and nothing else happens: no relay, no record,
/// nothing staged.
#[tokio::test]
async fn a_stranded_commit_handed_back_in_a_finish_only_plane_is_applied_and_nothing_is_made() {
    let (admin, peer, _, group, source, _) = a_stranded_removal(true).await;
    let admin = admin.reopen();
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let finish_only = within(&transport, &outbox, &clock, &FINISH_ONLY, 4 * ROW_BUDGET_MS);
    for tick in 0..6_u32 {
        if epoch(&admin, &group).await == source + 2 {
            break;
        }
        helpers::drive::wait_out_the_engine(&admin, &group).await;
        let fix = sealed_by(&peer, &group, f64::from(tick).mul_add(0.25, 20.0)).await;
        let _ = finish_only
            .ingest_for_poll(&admin.circle, &fix)
            .await
            .expect("a polled fix is ingested");
    }
    assert_eq!(
        epoch(&admin, &group).await,
        source + 2,
        "a stranded commit handed back in a finish-only plane was not applied",
    );
    assert!(
        transport.calls().is_empty()
            && outbox.handed().is_empty()
            && records_of(&admin, &group).await.is_empty()
            && staged_ref(&admin, &group).await.is_none()
            && unread(&admin, &group).is_empty(),
        "a finish-only hand-back called a relay, recorded, staged, or left its note",
    );
}

// ── No false positive ────────────────────────────────────────────────────────

/// A handed-back event the engine cannot open yet is the engine's again, held
/// as deferred, and Haven keeps nothing of it: no bytes, no id, and nothing
/// told. Here a fix from an epoch this device has not reached: once the
/// commit that leads there has arrived and had its pass, the engine opens
/// the fix by itself — delivered once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_handed_back_event_the_engine_defers_is_the_engines_again_and_nothing_of_it_is_kept() {
    let (admin, peer, group, source, removal) =
        a_fix_from_an_epoch_not_reached_stranded(false).await;
    let admin = admin.reopen();
    assert_eq!(unread(&admin, &group), [ChangeNote::UnreadLocation]);

    let mut delivered = fixes(
        &admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs"),
    );
    assert!(
        delivered.is_empty()
            && kept(&admin, &group).is_empty()
            && stranded(&admin, &group).await == 0
            && unread(&admin, &group).is_empty(),
        "an event the engine holds deferred again is still kept, or its circle is still told",
    );
    let _ = answer(admin.session(), &removal).await;
    delivered.extend(fixes(&served(admin.session(), &group).await));
    assert!(
        epoch(&admin, &group).await == source + 2
            && delivered.len() == 1
            && has_fix(&delivered, &peer, LATER),
        "the fix the engine deferred was not delivered once, by the engine, after its pass",
    );
    let admin = admin.reopen();
    assert!(kept(&admin, &group).is_empty() && unread(&admin, &group).is_empty());
}

/// A handed-back event the engine has no room to hold — it cannot open it,
/// and its store of what it cannot open is full — is refused, and the engine
/// keeps nothing of it. Haven keeps nothing of it either: it is owed its
/// refetch by id, as an event a relay delivered and the engine refused is
/// (Security Rule 12), and its circle is told nothing more — a note that
/// only such an event raised ends with it. Kept instead, events like it,
/// which anyone who knows the routing tag can send without number, would
/// stand in front of everything behind them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_handed_back_event_the_engine_has_no_room_for_ends_and_is_owed_its_refetch() {
    let (admin, _peer, group, _source, _removal) =
        a_fix_from_an_epoch_not_reached_stranded(true).await;
    let admin = admin.reopen();
    assert!(
        unread(&admin, &group) == [ChangeNote::UnreadLocation]
            && admin.session().refused_redeliveries(&group, 16).is_empty(),
        "premise: told of the stranded fix, and nothing owed a refetch yet",
    );
    let advanced = admin
        .session()
        .advance_for_receive(&group)
        .await
        .expect("the advance runs");
    assert!(
        fixes(&advanced).is_empty()
            && kept(&admin, &group).is_empty()
            && stranded(&admin, &group).await == 0,
        "an event the engine refused for want of room is still kept, or still parked",
    );
    assert!(
        unread(&admin, &group).is_empty(),
        "a note raised only by an event the engine has no room for did not end with it",
    );
    assert_eq!(
        admin.session().refused_redeliveries(&group, 16).len(),
        1,
        "an event the engine refused for want of room was not left owed its refetch",
    );
    // Durably: the next process still owes it, and is told nothing.
    let admin = admin.reopen();
    assert!(
        admin.session().refused_redeliveries(&group, 16).len() == 1
            && unread(&admin, &group).is_empty()
            && kept(&admin, &group).is_empty(),
    );
}

/// A row whose event Haven already keeps — the engine was handed the copy
/// once and would not take it, and the row was never released — is not
/// taken over a second time: the row is released and the kept copy handed
/// back in its place, once, behind the rows the engine has not yet seen.
#[tokio::test]
async fn a_row_whose_event_haven_already_keeps_is_released_and_its_copy_handed_back_once() {
    use nostr::JsonUtil as _;

    let (admin, others, group, _source, parked) = fixes_stranded_by_a_confirm(2).await;
    circle_store(&admin)
        .execute(
            "INSERT INTO kept_input (event_id, mls_group_id, seq, change, asked, event)
             VALUES (?1, ?2, 1, 0, 1, ?3)",
            rusqlite::params![
                parked[0].id.as_bytes().as_slice(),
                group.as_slice(),
                parked[0].as_json()
            ],
        )
        .expect("the first event is kept beside its row");
    let admin = admin.reopen();
    let delivered = fixes(
        &admin
            .session()
            .advance_for_receive(&group)
            .await
            .expect("the advance runs"),
    );
    assert!(
        delivered.len() == 2
            && has_fix(&delivered[..1], &others[1], latitude_of(1))
            && has_fix(&delivered[1..], &others[0], latitude_of(0))
            && stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "a row whose event was already kept was delivered twice, left parked, or put ahead \
         of a row the engine had not yet seen",
    );
}

/// A call hands back the whole of what its own circle holds stranded,
/// oldest first, before it does anything else for that circle — however
/// much that is. A call that makes no commit and runs inside a wake hands
/// back sixteen and stops: its own event is then not taken at all — the
/// engine is not asked, and the caller holds its cursor — and the next call
/// carries on, with what the first had been handed kept for it.
#[tokio::test]
async fn a_call_hands_back_sixteen_stranded_events_and_the_next_call_the_rest() {
    const STRANDED: usize = 17;
    for whole in [true, false] {
        let fx = setup_circle(2, &[ONE]).await;
        let (admin, others, group) = split(fx);
        let peer = &others[0];
        let source = epoch(&admin, &group).await;
        let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
        for index in 0..STRANDED {
            let fix = sealed_by(peer, &group, latitude_of(index)).await;
            assert!(parks(admin.session(), &fix).await, "premise: parked unread");
        }
        let admin = confirm_and_die(admin, pending, source + 1).await.reopen();
        let all_in_order =
            |delivered: &[haven_core::nostr::mls::types::LocationMessageResult]| {
                delivered.len() >= STRANDED
                    && (0..STRANDED)
                        .all(|index| has_fix(&delivered[index..=index], peer, latitude_of(index)))
            };

        if whole {
            let first = fixes(
                &admin
                    .session()
                    .advance_for_receive(&group)
                    .await
                    .expect("the advance runs"),
            );
            assert!(
                first.len() == STRANDED
                    && all_in_order(&first)
                    && stranded(&admin, &group).await == 0
                    && unread(&admin, &group).is_empty(),
                "a call did not hand back the whole of what its own circle held stranded",
            );
            continue;
        }
        let fresh = sealed_by(peer, &group, 60.0).await;
        let held_back = admin
            .session()
            .process_event_staging_for_test(&fresh, 1, &FINISH_ONLY)
            .await;
        assert!(
            matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
                && stranded(&admin, &group).await == 1
                && unread(&admin, &group) == [ChangeNote::UnreadLocation],
            "a call that makes no commit did not stop at sixteen, or took its own event ahead \
             of what its circle was still owed",
        );
        let (screened, _) = admin
            .session()
            .process_event_staging_for_test(&fresh, 1, &FINISH_ONLY)
            .await
            .expect("the next call carries on");
        let delivered = fixes(&screened.ingested().expect("ingested").effects);
        assert!(
            delivered.len() == STRANDED + 1
                && all_in_order(&delivered)
                && has_fix(&delivered[STRANDED..], peer, 60.0)
                && stranded(&admin, &group).await == 0
                && kept(&admin, &group).is_empty()
                && unread(&admin, &group).is_empty(),
            "the next call did not hand back the rest, ahead of its own event, with what the \
             first call had been handed",
        );
    }
}

/// A seal, a stage or an advance for a circle nothing is flagged in reads no
/// store for stranded input: the look is at the open, and after a confirm
/// or a rollback.
#[tokio::test]
async fn a_call_for_a_circle_nothing_is_flagged_in_reads_no_store_for_stranded_input() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let admin = admin.reopen();
    let at_the_open = admin.session().stranded_rows_examined_for_test();
    assert!(
        at_the_open >= 1,
        "premise: the open looks, and a look is counted"
    );

    for index in 0..3 {
        let _ = sealed_by(&admin, &group, latitude_of(index)).await;
        let fix = sealed_by(&others[0], &group, latitude_of(index)).await;
        assert!(matches!(
            answer(admin.session(), &fix).await,
            IngestOutcome::Processed
        ));
        let _ = served(admin.session(), &group).await;
        assert!(bounded_seal(&admin, &group).await);
    }
    assert_eq!(
        admin.session().stranded_rows_examined_for_test(),
        at_the_open,
        "a seal, an ingest or an advance read the engine's store for stranded input with \
         nothing flagged",
    );
}

/// Looking for stranded input does bounded work however many rows an
/// outsider has parked — and needs no death to have some: with the engine's
/// deferral store full, the confirm's own replay has no room for a row it
/// cannot open and leaves it as it arrived (v0.10.4 `message_processor/
/// mod.rs` 3634-3655), in a circle that then holds nothing pending. The look
/// after that confirm, an open, the call that takes the rows over and a
/// relay serving them again each read a number of rows the cap bounds, never
/// one the sender chose; and the circle is told what the rows claim to be.
#[tokio::test]
async fn looking_for_stranded_input_does_bounded_work_however_many_rows_an_outsider_parked() {
    const PARKED: usize = 600;
    const SERVED_AGAIN: usize = 24;
    // One scan: the listing, and one row more than a circle may have kept.
    const SCAN: usize = KEPT_EVENTS_PER_CIRCLE + 2;
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let like = sealed_by(&others[0], &group, 0.5).await;
    // Staged over an empty store: over a full one, MDK's wall-clocked
    // foreground preflight could queue the change (see the fixture
    // `a_fix_from_an_epoch_not_reached_stranded`). Parked first, these fill
    // the store in the confirm's replay.
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    for index in 0..MAX_PEEL_DEFERRED_ROWS_PER_GROUP {
        let envelope = unopenable(&like, u32::try_from(index).expect("small"));
        assert!(
            parks(admin.session(), &envelope).await,
            "premise: parked unread"
        );
    }
    let mut parked = Vec::new();
    for index in 0..PARKED {
        let envelope = unopenable(&like, 1_000_000 + u32::try_from(index).expect("small"));
        assert!(
            parks(admin.session(), &envelope).await,
            "premise: parked unread"
        );
        parked.push(envelope);
    }
    let examined = |member: &CircleMember| member.session().stranded_rows_examined_for_test();

    let before = examined(&admin);
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the confirm completes: no death, no error");
    assert!(
        stranded(&admin, &group).await == PARKED
            && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "what the confirm's replay had no room for is not stranded, or its circle is not told \
         what the rows claim to be",
    );
    assert!(
        examined(&admin) - before <= SCAN,
        "the look after a confirm examined every row an outsider parked",
    );

    let admin = admin.reopen();
    assert!(
        examined(&admin) <= SCAN && unread(&admin, &group) == [ChangeNote::UnreadLocation],
        "the look at an open examined every row an outsider parked, or lost the note",
    );

    // A call hands back its room's worth — each row a read and an ingest —
    // and answers held; nothing of what the engine then refuses is kept.
    let before = examined(&admin);
    let held_back = admin.session().advance_for_receive(&group).await;
    assert!(
        matches!(held_back, Err(haven_core::nostr::NostrError::EngineHeld))
            && kept(&admin, &group).is_empty()
            && stranded(&admin, &group).await == PARKED - HAND_BACK_WHOLE
            && examined(&admin) - before <= 2 * SCAN,
        "the call that took the rows over took more than its room, kept what the engine \
         refused, or examined every row an outsider parked",
    );

    // A relay serves the rows again. While any of the circle's can still be
    // handed back a delivery for it is held, and hands back its room's
    // worth — a slice, beside a plane only started; once none is left, a row
    // served again is an event the engine has no room for, like any other.
    let routing = ngid(&admin, &group).await;
    let processor = EngineProcessor::new(std::sync::Arc::clone(&admin.circle), EventBus::new());
    let before = examined(&admin);
    let mut held_back = 0;
    for envelope in parked.iter().rev().take(SERVED_AGAIN) {
        match processor.process_group_event(envelope, &routing).await {
            GroupProcessOutcome::Held => held_back += 1,
            GroupProcessOutcome::Refused => {}
            _ => panic!(
                "a row served again was neither held behind what its circle was still owed \
                 nor refused for want of room"
            ),
        }
    }
    assert_eq!(
        held_back,
        (PARKED - HAND_BACK_WHOLE - 1) / HAND_BACK_SLICE,
        "the deliveries that were held are not the ones that still had rows to hand back",
    );
    // Two scans for each call that handed rows back — the hand-back's, and
    // the one that tells — and a row or two for each event served.
    assert!(
        examined(&admin) - before <= (held_back + 1) * 2 * SCAN + 2 * SERVED_AGAIN,
        "a relay serving stranded rows again had the circle scanned for each",
    );
    assert!(
        stranded(&admin, &group).await == 0
            && kept(&admin, &group).is_empty()
            && unread(&admin, &group).is_empty(),
        "with nothing of the flood left to hand back, something is still kept, or the \
         circle is still told: an outsider keeps a note standing for as long as it likes",
    );
}

/// A healthy circle is told nothing and has nothing taken over, through
/// everything a circle legitimately holds for later: a kept leave, a fix
/// from an epoch not yet reached, a commit awaiting its pass, a commit of
/// its own pending under a record across a restart with a fix parked behind
/// it, that commit's confirm and a later rollback, and — on the device that
/// left — what a removed copy is handed. Every open, every confirm and every
/// rollback on the way looks.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn a_healthy_circle_is_told_nothing_and_nothing_of_it_is_taken_over() {
    fn quiet(member: &CircleMember, group: &GroupId, at: &str) {
        assert!(
            unread(member, group).is_empty() && kept(member, group).is_empty(),
            "a healthy circle was told it holds unread input, or had some taken over: {at}",
        );
    }
    let fx = setup_circle(3, &[ONE]).await;
    let leave = helpers::drive::leave_of(&fx, 2).await;
    let (admin, others, group) = split(fx);
    let (peer, leaver) = (&others[0], &others[1]);
    let source = epoch(&admin, &group).await;

    let _ = answer(admin.session(), &leave).await;
    let _ = answer(admin.session(), &sealed_by(peer, &group, 10.5).await).await;
    let admin = admin.reopen();
    quiet(&admin, &group, "a kept leave, across a restart");

    let _ = answer(peer.session(), &leave).await;
    helpers::drive::wait_out_the_engine(peer, &group).await;
    let advanced = peer
        .session()
        .stage_unrecorded_for_test(&group)
        .await
        .expect("the advance runs");
    let (eviction, their_pending) = staged(&advanced);
    peer.session()
        .confirm_published(their_pending)
        .await
        .expect("the eviction is confirmed");
    let ahead = sealed_by(peer, &group, 11.5).await;
    let _ = answer(admin.session(), &ahead).await;
    let _ = answer(admin.session(), &eviction).await;
    let before = held(admin.session(), &group).await.len();
    let admin = admin.reopen();
    assert_eq!(
        held(admin.session(), &group).await.len(),
        before,
        "an open touched a deferred fix or a commit awaiting its pass",
    );
    quiet(
        &admin,
        &group,
        "a deferred fix and a commit awaiting its pass",
    );
    let _ = served(admin.session(), &group).await;
    assert_eq!(epoch(&admin, &group).await, source + 1, "premise");
    quiet(&admin, &group, "after the pass");

    // A commit of its own, pending under its record, a fix parked behind it.
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .update_relays(&admin.circle, &group, &[ONE.to_owned(), TWO.to_owned()])
        .await
        .expect("a relay change is recorded and sent");
    let parked = sealed_by(peer, &group, 12.5).await;
    assert!(parks(admin.session(), &parked).await, "premise");
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && all_parked_at(&held(admin.session(), &group).await, 1, source + 1),
        "premise: the commit is still pending and the fix parked behind it",
    );
    quiet(&admin, &group, "a fix parked behind a commit still pending");
    assert!(
        parks(admin.session(), &parked).await
            && all_parked_at(&held(admin.session(), &group).await, 1, source + 1),
        "an ingest touched a row parked behind a commit that is still pending",
    );
    quiet(&admin, &group, "after an ingest behind the pending commit");

    // Its confirm: the engine's own replay delivers the fix.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(31_000);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        has_fix(&resumed.replayed, peer, 12.5) && epoch(&admin, &group).await == source + 2,
        "premise: the confirm replayed what was parked",
    );
    quiet(&admin, &group, "after a confirm");

    // A rollback of its own.
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE]).await;
    let parked = sealed_by(peer, &group, 13.5).await;
    assert!(parks(admin.session(), &parked).await, "premise");
    let rolled = admin
        .session()
        .publish_failed(pending)
        .await
        .expect("the rollback runs");
    assert!(has_fix(&fixes(&rolled), peer, 13.5), "premise");
    quiet(&admin, &group, "after a rollback");
    let admin = admin.reopen();
    quiet(&admin, &group, "at the last open");

    // The device that left: what its removed copy is handed is the engine's
    // to keep for a join.
    let _ = answer(leaver.session(), &eviction).await;
    let _ = served(leaver.session(), &group).await;
    let after = sealed_by(peer, &group, 14.5).await;
    let _ = answer(leaver.session(), &after).await;
    assert_eq!(
        stranded(leaver, &group).await,
        1,
        "premise: a removed copy keeps what it is handed",
    );
    let again = sealed_by(peer, &group, 15.5).await;
    let _ = answer(leaver.session(), &again).await;
    assert!(
        stranded(leaver, &group).await == 2
            && kept(leaver, &group).is_empty()
            && leaver.session().peek_change_notes(&group).is_empty(),
        "what a removed copy keeps for a join was taken over, or told as unread",
    );
}

/// A session with no store behind it can keep nothing, so it releases
/// nothing: the engine's rows stand, and it is told for as long as it lives.
#[tokio::test]
async fn a_session_with_no_store_to_keep_an_event_in_releases_none() {
    let (admin, _, group, source, parked) = fixes_stranded_by_a_confirm(2).await;
    let engine = bare(admin);
    let _ = served(&engine.session, &group).await;
    assert!(
        all_parked_at(&held(&engine.session, &group).await, 2, source)
            && parks(&engine.session, &parked[0]).await
            && engine
                .session
                .peek_change_notes(&group)
                .contains(&ChangeNote::UnreadLocation),
        "a session that could keep nothing released a stranded row, or was not told",
    );
}

/// What Haven kept for a circle is destroyed when this device is no longer
/// in it: the removal is seen by the engine alone, and the next open with
/// the circle's store finds the circle gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn what_was_kept_for_a_circle_is_destroyed_once_this_device_is_out_of_it() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let group = fx.group.clone();
    let mut members = fx.members;
    let third = members.remove(2);
    let device = members.remove(1);
    let admin = members.remove(0);
    let source = epoch(&device, &group).await;
    let (mine, pending) = stage_relays(device.session(), &group, &[ONE, TWO]).await;
    let parked = sealed_by(&third, &group, 70.5).await;
    assert!(parks(device.session(), &parked).await);
    let device = confirm_and_die(device, pending, source + 1).await.reopen();
    device
        .session()
        .stop_hand_back_for_test(HandBackStop::Kept, 0);
    let _ = device.session().advance_for_receive(&group).await;
    assert_eq!(kept(&device, &group), [false], "premise");

    let engine = bare(device);
    admin
        .session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the admin applies the commit");
    for change in [true, false] {
        let effects = if change {
            admin
                .session()
                .update_admin_policy(&group, &[admin.keys.public_key().to_bytes()])
                .await
        } else {
            admin
                .session()
                .remove_members(&group, &[engine.keys.public_key().to_hex()])
                .await
        }
        .expect("the change is staged");
        let (event, pending) = staged(&effects);
        admin
            .session()
            .confirm_published(pending)
            .await
            .expect("confirmed");
        engine
            .session
            .process_event_settled_for_test(&event)
            .await
            .expect("the device sees it");
    }
    assert!(
        !engine.session.group_is_live(&group).await,
        "premise: removed"
    );

    let device = engine.with_its_circle_store();
    assert!(
        kept(&device, &group).is_empty() && unread(&device, &group).is_empty(),
        "what was kept for a circle this device was removed from outlived the removal",
    );
}
