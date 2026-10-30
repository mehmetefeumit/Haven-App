//! A location rides a durable record that ends at its expiration.
//!
//! Its record is written in the engine hold that seals it, before any relay
//! is written to, and no relay is handed the event within a send's window of
//! its NIP-40 `expiration`. A send that returned is never repeated, and the
//! send is made only if a fresh seal for the circle would be made then. A
//! location whose send a process did not finish is never sent by another
//! process: its record is deleted without a relay being contacted. A
//! location never holds a commit back, and a drive never touches a location
//! whose send is under way.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted, so
//! no socket is opened and no clock but the driver's own is waited on.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{
    fanout_writes_for_test, set_engine_write_fault_for_test, EngineWrite,
};
use haven_core::nostr::mls::types::{FanoutProbe, FanoutTargetStatus, GroupId};
use haven_core::relay::fanout::scripted::{Answer, LocationAnswer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, EvolutionStatus, LocationPublish, LocationSeal, Publishing, SendHeld,
    LOCATION_SEND_MS, ROW_BUDGET_MS,
};
use haven_core::relay::RelayError;
use helpers::drive::{epoch, ngid, through, within, ManualClock, Recorder};
use helpers::stranded::{answer, co_admin, fixes_stranded_by_a_confirm, mls_db, split, staged};
use helpers::{assert_no_needles, capture_haven_log, setup_circle, CircleMember};

const ONE: &str = "wss://one.location-canary4e1b.example.com";
const TWO: &str = "wss://two.location-canary4e1b.example.com";
const FULL: DriveMode = DriveMode::Full;
const FINISH_ONLY: DriveMode = DriveMode::FinishOnly;
const ROOM_MS: u64 = 2 * ROW_BUDGET_MS;

fn fix() -> LocationMessage {
    LocationMessage::new(51.5, -0.12)
}

/// The location records `member` holds for `group`.
async fn records(member: &CircleMember, group: &GroupId) -> Vec<FanoutProbe> {
    member
        .session()
        .location_records_for_test(group)
        .await
        .expect("the store is read")
}

/// A location `member` seals through `driver`: its event and the relays the
/// driver says to send it to.
async fn sealed(
    driver: &Publishing<'_, ScriptedFanout>,
    member: &CircleMember,
    group: &GroupId,
) -> (nostr::Event, Vec<String>) {
    let outcome = driver
        .seal_location(&member.circle, group, &fix())
        .await
        .expect("the seal runs");
    match outcome.seal {
        LocationSeal::Sealed { event, relays, .. } => (*event, relays),
        LocationSeal::Deferred(_) => panic!("premise: the send is sealed"),
    }
}

/// Where the driver's clock must be set for `event` to expire `before_ms`
/// later.
fn before_expiry(event: &nostr::Event, before_ms: u64) -> u64 {
    let expires_ms = event
        .tags
        .expiration()
        .expect("a location carries its expiration")
        .as_secs()
        * 1_000;
    expires_ms - before_ms - ManualClock::ORIGIN
}

/// A location's record is written by the seal, before any relay is written
/// to; it holds no commit back; and it ends, unsent and with no relay
/// contacted, once a send begun now could not finish before the event
/// expires.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_application_fanout_ends_at_its_expiration_and_never_blocks() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    let (event, relays) = sealed(&driver, &admin, &group).await;
    let stored = records(&admin, &group).await;
    // `assert!`, not `assert_eq!`: an event id is never formatted (Security
    // Rule 15).
    assert!(
        stored.len() == 1
            && stored[0].event_id == event.id
            && stored[0].targets == [ONE]
            && relays == [ONE]
            && stored[0].statuses == [FanoutTargetStatus::NotAttempted],
        "a sealed location has no record of its own, frozen for its circle's relays, before \
         any relay is written to",
    );
    assert!(
        transport.location_call_count() == 0,
        "the seal wrote to a relay"
    );

    // A change of the circle is staged, sent and applied with that record
    // standing.
    transport.answer(ONE, [Answer::Accepted]);
    let before = epoch(&admin, &group).await;
    let removed = driver
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("the removal is accepted");
    assert!(
        removed.status == EvolutionStatus::Confirmed
            && epoch(&admin, &group).await == before + 1
            && transport.calls().len() == 1,
        "a location's record held a commit back",
    );
    assert!(
        records(&admin, &group).await.len() == 1 && transport.location_call_count() == 0,
        "a commit's drive sent, or ended, a location that was not its own",
    );

    // A second sealed here, with a whole send's window and a millisecond
    // more before it expires: still standing after a drive.
    let (event, _) = sealed(&driver, &admin, &group).await;
    clock.set(before_expiry(&event, LOCATION_SEND_MS + 1));
    let _ = driver.resume(&admin.circle).await;
    assert!(
        records(&admin, &group)
            .await
            .iter()
            .any(|record| record.event_id == event.id),
        "a location's record was ended while a send of it could still finish in time",
    );
    // A millisecond later a send could not: every record that old ends, and
    // no relay is contacted for it.
    clock.set(before_expiry(&event, LOCATION_SEND_MS));
    let _ = driver.resume(&admin.circle).await;
    assert!(
        records(&admin, &group).await.is_empty() && transport.location_call_count() == 0,
        "a location's record outlived its event's expiration, or a relay was contacted for \
         a location that had expired",
    );
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Ended
        ) && transport.location_call_count() == 0,
        "a location whose record had ended was sent",
    );

    // And its own send, asked for too late, ends it the same way.
    clock.set(0);
    let (event, _) = sealed(&driver, &admin, &group).await;
    clock.set(before_expiry(&event, LOCATION_SEND_MS));
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Expired
        ) && records(&admin, &group).await.is_empty()
            && transport.location_call_count() == 0,
        "a location was sent at its expiration, or its record was kept past it",
    );
}

/// A send that returned — acknowledged or not — is never made again: its
/// record is gone with the answer, a second call for the event sends
/// nothing, and neither does any drive, in this process or the next. And it
/// cost the store two writes: the record's put and its delete.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_completed_location_send_is_never_retried_and_costs_two_writes() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (mut admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let (db, key) = mls_db(admin.dir.path());

    for answer in [LocationAnswer::Accepted, LocationAnswer::Unanswered] {
        transport.answer_locations(answer);
        let driver = through(&transport, &outbox, &clock, &FULL);
        let _ = fanout_writes_for_test(&db, &key).expect("the count starts");
        let (event, _) = sealed(&driver, &admin, &group).await;
        let sent = driver.publish_location(&admin.circle, &event).await;
        assert!(
            match (answer, sent) {
                (LocationAnswer::Accepted, LocationPublish::Sent(Ok(result))) =>
                    result.accepted_by == [ONE, TWO],
                (LocationAnswer::Unanswered, LocationPublish::Sent(Err(error))) =>
                    matches!(error, RelayError::AllRelaysFailed),
                _ => false,
            },
            "the transport's own answer did not come back unchanged",
        );
        assert_eq!(
            fanout_writes_for_test(&db, &key).expect("the count is read"),
            2,
            "a location's send did not cost the store exactly its record's put and its delete",
        );
        assert!(
            records(&admin, &group).await.is_empty() && transport.location_calls().len() == 1,
            "a send that returned left its record behind, or was made more than once",
        );

        assert!(
            matches!(
                driver.publish_location(&admin.circle, &event).await,
                LocationPublish::Ended
            ),
            "a second call for a location already sent was not refused",
        );
        let _ = driver.resume(&admin.circle).await;
        admin = admin.reopen();
        let _ = through(&transport, &outbox, &clock, &FULL)
            .resume(&admin.circle)
            .await;
        assert!(
            transport.location_call_count() == 0,
            "a completed location send was made again",
        );
    }
}

/// A location whose send a process did not finish is never sent by another
/// process (decision 212): the core cannot tell whether its user still
/// shares. Its record is deleted without a relay being contacted — by the
/// next process's drive, in either mode and with any time left, and by the
/// drive a change makes first — whether the process died before the send
/// or inside it, and whether or not the event has expired.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_whose_send_a_process_did_not_finish_is_never_sent_by_another() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (mut admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);

    // Sealed, and the process dies before the send: a full drive with a
    // whole wake, and a drive that only finishes with almost none.
    for (mode, room_ms) in [(&FULL, ROOM_MS), (&FINISH_ONLY, 1)] {
        let _ = sealed(&through(&transport, &outbox, &clock, &FULL), &admin, &group).await;
        admin = admin.reopen();
        let _ = within(&transport, &outbox, &clock, mode, room_ms)
            .resume(&admin.circle)
            .await;
        assert!(
            transport.location_call_count() == 0 && records(&admin, &group).await.is_empty(),
            "a drive sent a location another process sealed, or left its record standing",
        );
    }

    // The process dies INSIDE the send.
    let driver = through(&transport, &outbox, &clock, &FULL);
    let (event, _) = sealed(&driver, &admin, &group).await;
    transport.park_next_location();
    {
        let sending = driver.publish_location(&admin.circle, &event);
        tokio::pin!(sending);
        tokio::select! {
            biased;
            () = transport.parked() => {}
            _ = &mut sending => panic!("premise: the send is under way"),
        }
    }
    transport.release(1);
    assert!(
        transport.location_calls().len() == 1 && records(&admin, &group).await.len() == 1,
        "premise: the send was begun and its record outlived the process",
    );
    let admin = admin.reopen();
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.location_call_count() == 0 && records(&admin, &group).await.is_empty(),
        "a location whose send a dead process began was sent again, or its record was kept",
    );

    // The drive a change makes first sends no stale fix before it.
    let _ = sealed(&through(&transport, &outbox, &clock, &FULL), &admin, &group).await;
    let admin = admin.reopen();
    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Accepted]);
    let removed = through(&transport, &outbox, &clock, &FULL)
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("the removal is accepted");
    assert!(
        removed.status == EvolutionStatus::Confirmed
            && transport.location_call_count() == 0
            && records(&admin, &group).await.is_empty(),
        "a change's first drive sent a location another process sealed",
    );

    // Expired, the same.
    let (event, _) = sealed(&through(&transport, &outbox, &clock, &FULL), &admin, &group).await;
    let admin = admin.reopen();
    clock.set(before_expiry(&event, LOCATION_SEND_MS));
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.location_call_count() == 0 && records(&admin, &group).await.is_empty(),
        "an expired location another process sealed was sent, or its record was kept",
    );
}

/// A location goes to the relays its record froze in the hold that sealed
/// it — what the circle's routing named then — and to no other: not to what
/// the circle's stored row says.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_is_published_to_its_fanouts_frozen_targets() {
    const ELSEWHERE: &str = "wss://three.location-canary4e1b.example.com";
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    // The circle's row no longer says what its routing does.
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let rows = rusqlite::Connection::open(
        admin
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .execute(
        "UPDATE circles SET relays = ?1",
        [format!("[\"{ELSEWHERE}\"]")],
    )
    .expect("the row is rewritten");
    assert_eq!(rows, 1, "premise");

    let (event, relays) = sealed(&driver, &admin, &group).await;
    let stored = records(&admin, &group).await;
    assert!(
        relays == [ONE, TWO] && stored.len() == 1 && stored[0].targets == [ONE, TWO],
        "a location's record was not frozen for the relays its circle's routing names",
    );
    let sent = driver.publish_location(&admin.circle, &event).await;
    let calls = transport.location_calls();
    assert!(
        matches!(sent, LocationPublish::Sent(Ok(_)))
            && calls.len() == 1
            && calls[0].targets == [ONE, TWO],
        "a location was sent somewhere other than the relays its record froze",
    );
}

/// A drive never touches a location whose send is under way: it sends
/// nothing, ends nothing, and a second call for the same event is told so.
/// And a commit staged while a location is on its way to a relay goes to
/// that relay at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_concurrent_drive_never_touches_an_in_flight_location() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    // Its own send, under way.
    let (event, _) = sealed(&driver, &admin, &group).await;
    transport.park_next_location();
    {
        let sending = driver.publish_location(&admin.circle, &event);
        tokio::pin!(sending);
        tokio::select! {
            biased;
            () = transport.parked() => {}
            _ = &mut sending => panic!("premise: the send is under way"),
        }
        let _ = driver.resume(&admin.circle).await;
        assert!(
            matches!(
                driver.publish_location(&admin.circle, &event).await,
                LocationPublish::InFlight
            ),
            "a second send of a location was begun while its first was under way",
        );
        assert!(
            transport.location_call_count() == 1 && records(&admin, &group).await.len() == 1,
            "a concurrent drive sent, or ended, a location whose send was under way",
        );
        // A commit staged meanwhile is sent to the same relay at once.
        transport.answer(ONE, [Answer::Accepted]);
        let removed = driver
            .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
            .await
            .expect("the removal is accepted");
        assert!(
            removed.status == EvolutionStatus::Confirmed && transport.calls().len() == 1,
            "a location on its way to a relay made a commit wait for that relay",
        );
        transport.release(1);
        assert!(matches!(sending.await, LocationPublish::Sent(Ok(_))));
    }
    assert!(transport.location_calls().len() == 1 && records(&admin, &group).await.is_empty());
}

/// A location sealed before a commit this device has applied is never
/// handed to a relay once the send begins: the commit may have removed a
/// member, who can still read what was sealed before. Not by its own send,
/// however late the caller makes it, and not by the drive of the process
/// after a kill.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_sealed_before_a_removal_is_never_sent_after_it() {
    let fx = setup_circle(4, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let remove = |leaver: String| {
        let (driver, admin, group) = (&driver, &admin, &group);
        async move {
            let removed = driver
                .remove_members(&admin.circle, group, &[leaver])
                .await
                .expect("the removal is accepted");
            assert!(removed.status == EvolutionStatus::Confirmed, "premise");
        }
    };

    let (event, _) = sealed(&driver, &admin, &group).await;
    remove(others[2].pubkey_hex()).await;
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Superseded
        ) && transport.location_call_count() == 0
            && records(&admin, &group).await.is_empty(),
        "a location sealed before a removal was sent after it, or its record was kept",
    );

    let _ = sealed(&driver, &admin, &group).await;
    remove(others[1].pubkey_hex()).await;
    assert!(
        records(&admin, &group).await.len() == 1,
        "premise: sealed before the removal, and still recorded",
    );
    let admin = admin.reopen();
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.location_call_count() == 0 && records(&admin, &group).await.is_empty(),
        "a location sealed before a removal was sent after it by the next process",
    );
}

/// A location this device sealed is not sent once it has been removed from
/// its circle: MDK's own rule is that a removed copy never publishes, and
/// the circle that removed it would receive where it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_is_not_sent_once_this_device_has_been_removed() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let member = &others[0];
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    let (event, _) = sealed(&driver, member, &group).await;
    let removal = admin
        .session()
        .remove_members(&group, &[member.pubkey_hex()])
        .await
        .expect("the admin removes the member");
    let (commit, pending) = staged(&removal);
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("and its relays took the commit");
    let _ = member
        .session()
        .process_event_settled_for_test(&commit)
        .await;
    assert!(
        matches!(
            driver.publish_location(&member.circle, &event).await,
            LocationPublish::Superseded
        ) && transport.location_call_count() == 0
            && records(member, &group).await.is_empty(),
        "a location was sent by a device its circle had removed, or its record was kept",
    );
}

/// A location sealed by a device the circle has since removed is never sent:
/// a removed copy never publishes (MDK's own rule), and the removal's
/// commit, which the device cannot open, leaves its epoch where it was.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_sealed_before_this_device_was_removed_is_never_sent() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let member = &others[0];
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    let (event, _) = sealed(&driver, member, &group).await;
    let removal = admin
        .session()
        .remove_members(&group, &[member.pubkey_hex()])
        .await
        .expect("the admin removes the member");
    let (commit, pending) = staged(&removal);
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("and its relays took the commit");
    let _ = member
        .session()
        .process_event_settled_for_test(&commit)
        .await;
    assert!(
        member.session().removed_for_test(&group).await,
        "premise: the device knows it was removed",
    );
    assert!(
        matches!(
            driver.publish_location(&member.circle, &event).await,
            LocationPublish::Superseded
        ) && transport.location_call_count() == 0
            && records(member, &group).await.is_empty(),
        "a location was sent for a circle that had removed this device, or its record was kept",
    );
}

/// A copy marked removed sends nothing, though nothing else has moved: the
/// record reads Stable at the epoch the location was sealed at, and the
/// removed clause alone refuses it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_of_a_copy_marked_removed_at_its_epoch_is_never_sent() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let (event, _) = sealed(&driver, &admin, &group).await;
    let before = epoch(&admin, &group).await;
    let (db, key) = mls_db(admin.dir.path());
    haven_core::nostr::mls::storage::mark_group_removed_for_test(&db, &key, &group)
        .expect("the copy is marked removed");
    assert!(
        admin.session().removed_for_test(&group).await && epoch(&admin, &group).await == before,
        "premise: marked removed, the epoch unmoved",
    );
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Superseded
        ) && transport.location_call_count() == 0,
        "a location of a copy marked removed was sent",
    );
}

/// A location is not sent while its circle holds a commit it took in and has
/// not resolved: MDK would queue a fresh one there, and that commit may
/// remove a member who could read it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_is_not_sent_while_a_commit_its_circle_took_in_is_unresolved() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, others, group) = split(fx);
    let (co, removed) = (&others[0], &others[1]);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    let (event, _) = sealed(&driver, &admin, &group).await;
    let removal = co
        .session()
        .remove_members(&group, &[removed.pubkey_hex()])
        .await
        .expect("the co-admin removes a member");
    let (commit, pending) = staged(&removal);
    co.session()
        .confirm_published(pending)
        .await
        .expect("and its relays took it");
    let before = epoch(&admin, &group).await;
    let _ = answer(admin.session(), &commit).await;
    assert!(
        epoch(&admin, &group).await == before
            && admin.session().has_pending_inputs_for_test(&group).await,
        "premise: the removal is taken in and not yet resolved",
    );
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Superseded
        ) && transport.location_call_count() == 0
            && records(&admin, &group).await.is_empty(),
        "a location was sent while its circle held a removal it had not resolved",
    );
}

/// A location this session did not seal is never sent by it: a record a
/// reopened session finds is another's, whatever process it is in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_another_session_sealed_is_never_sent_by_this_one() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let (event, _) = sealed(&through(&transport, &outbox, &clock, &FULL), &admin, &group).await;
    let admin = admin.reopen();
    let driver = through(&transport, &outbox, &clock, &FULL);
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::Superseded
        ) && transport.location_call_count() == 0
            && records(&admin, &group).await.is_empty(),
        "a session sent a location another session had sealed",
    );
}

/// A burst's own location — the reason it runs — is sealed, recorded and
/// sent by a drive that only finishes, like any other; one a dead process
/// left is deleted unsent by the same drive.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_that_only_finishes_sends_its_own_location_and_deletes_an_interrupted_one() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);

    let _ = sealed(&through(&transport, &outbox, &clock, &FULL), &admin, &group).await;
    let admin = admin.reopen();
    let narrow = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let (own, _) = sealed(&narrow, &admin, &group).await;
    let _ = narrow.resume(&admin.circle).await;
    let left = records(&admin, &group).await;
    assert!(
        transport.location_call_count() == 0 && left.len() == 1 && left[0].event_id == own.id,
        "a drive that only finishes sent the location a dead process left, kept its record, \
         or touched the burst's own before its send",
    );
    assert!(
        matches!(
            narrow.publish_location(&admin.circle, &own).await,
            LocationPublish::Sent(Ok(_))
        ) && transport.location_calls().len() == 1
            && records(&admin, &group).await.is_empty(),
        "a burst's own location was not sent",
    );
}

/// A location whose record cannot be written is not handed out to be sent:
/// the seal fails, with nothing stored, and the next one is sealed and
/// recorded as usual. What is logged of it names no circle, no member and
/// no relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_whose_record_cannot_be_written_is_never_handed_out() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let (db, key) = mls_db(admin.dir.path());

    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("armed");
    let mut unrecorded = None;
    let at = fix();
    let lines = capture_haven_log(async {
        let sealing = Box::pin(driver.seal_location(&admin.circle, &group, &at));
        unrecorded = Some(sealing.await);
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarmed");
    assert!(
        unrecorded.is_some_and(|sealed| sealed.is_err())
            && records(&admin, &group).await.is_empty(),
        "a location was handed out to be sent though its record could not be written",
    );
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        lines.iter().any(|line| line
            .message
            .contains("a sealed location could not be recorded")),
        "premise: the failure is logged, so the capture is not vacuous",
    );
    assert_no_needles(
        &lines,
        &[
            &hex::encode(group.as_slice()),
            &hex::encode(ngid(&admin, &group).await),
            &admin.pubkey_hex(),
            // The relays' own label, less the word the log line itself uses.
            "canary4e1b.example",
        ],
    );
    let _ = sealed(&driver, &admin, &group).await;
    assert!(
        records(&admin, &group).await.len() == 1,
        "the next location was not sealed and recorded",
    );
}

/// A seal that is held or deferred writes no record: nothing is sealed, and
/// nothing is left that a later drive could send from the background.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_seal_that_is_held_or_deferred_writes_no_record() {
    // A commit of this device's awaits its relays.
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Unreachable]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _ = driver
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("the removal is accepted");
    let held = driver
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the send is answered");
    assert!(
        matches!(held.seal, LocationSeal::Deferred(SendHeld::AwaitingRelays))
            && records(&admin, &group).await.is_empty(),
        "a send deferred behind a pending commit was sealed, or left a record",
    );

    // More stranded input than a call that makes no commit hands back: the
    // engine is not had for the send, and that is a deferral, typed.
    let (admin, _others, group, _source, parked) = fixes_stranded_by_a_confirm(17).await;
    let admin = admin.reopen();
    let narrow = within(&transport, &outbox, &clock, &FINISH_ONLY, ROOM_MS);
    let held = narrow
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("a held engine is a deferral, not a failure");
    assert!(
        matches!(held.seal, LocationSeal::Deferred(SendHeld::StoredInput))
            && held.retry_after_ms == Some(0)
            && records(&admin, &group).await.is_empty(),
        "a send made while stranded input was still owed to its circle was sealed, left a \
         record, or was not answered as a deferral to call again",
    );
    let next = narrow
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the next call carries on");
    assert!(
        matches!(next.seal, LocationSeal::Sealed { .. })
            && next.replayed.len() == parked.len()
            && records(&admin, &group).await.len() == 1,
        "once everything stranded had been handed back the send was not sealed and recorded",
    );
}
