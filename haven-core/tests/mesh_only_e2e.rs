//! `Publishing::seal_for_mesh`: a location sealed for the Bluetooth mesh
//! alone (plan §7.7 R1; T-BG-2's core half, T-BRIDGE-4's producer, T-SEC-7).
//!
//! A burst whose receive failed may still put a location on the radio. Such
//! a seal calls no relay — not for a commit of this device's that is
//! pending, not for what its hold hands back — and what it seals is sent to
//! no relay by any later call, in this process or another: its send hands
//! it to the mesh, as the format no member passes on to a relay, and ends
//! its record. What holds a relay seal holds this one.
//!
//! Real MDK engines over `SQLCipher` stores and the real hand-off. Every
//! driver here runs over relays that note each call of every kind made to
//! them.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use futures::FutureExt as _;
use haven_core::location::LocationMessage;
use haven_core::mesh::packet::{open, Format, MeshKey, Packet};
use haven_core::nostr::mls::storage::set_fanout_write_fault_naming_for_test;
use haven_core::nostr::mls::types::{FanoutProbe, GroupId};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, EvolutionStatus, LeaveStatus, LocationPublish, LocationSeal, Publishing, SendHeld,
    LOCATION_SEND_MS,
};
use helpers::drive::{
    disband, epoch, has_fix, leave_of, make_a_departure_due, newest_commit_row, records_of,
    staged_ref, stored_fix, through, wait_out_the_engine, ManualClock, Recorder, HOUR_MS,
};
use helpers::mesh::{
    a_leave_minted_again, handed_off, mesh_on, rows, waiting, wall_ms, WatchedRelays,
};
use helpers::stranded::{
    fixes_stranded_by_a_confirm, held, latitude_of, mls_db, split, stage_relays,
};
use helpers::{found_circle, setup_circle, CircleMember};
use nostr::Event;

const ONE: &str = "wss://one.mesh-only.example.com";
const TWO: &str = "wss://two.mesh-only.example.com";
const FULL: DriveMode = DriveMode::Full;
/// Where every seal here puts its fix.
const LATITUDE: f64 = 51.5;

/// A driver over relays that note every call, in `mode`, with no end to its
/// wake.
fn over<'a>(
    relays: &'a WatchedRelays,
    clock: &'a ManualClock,
    mode: &'a DriveMode,
) -> Publishing<'a, WatchedRelays> {
    Publishing {
        fanout: relays,
        publisher: relays,
        clock,
        deadline_ms: None,
        mode,
    }
}

fn fix() -> LocationMessage {
    LocationMessage::new(LATITUDE, -0.12)
}

/// What `member` is answered when it seals for the mesh alone.
async fn seal(
    driver: &Publishing<'_, WatchedRelays>,
    member: &CircleMember,
    group: &GroupId,
) -> LocationSeal {
    (driver.seal_for_mesh(&member.circle, group, &fix()).await)
        .expect("the seal runs")
        .seal
}

/// A location `member` seals for the mesh alone.
async fn sealed(
    driver: &Publishing<'_, WatchedRelays>,
    member: &CircleMember,
    group: &GroupId,
) -> Event {
    match seal(driver, member, group).await {
        LocationSeal::Sealed { event, .. } => *event,
        LocationSeal::Deferred(held_by) => panic!("premise: the seal is made, not {held_by:?}"),
    }
}

/// What holds `member`'s seal for the mesh alone.
async fn held_by(
    driver: &Publishing<'_, WatchedRelays>,
    member: &CircleMember,
    group: &GroupId,
) -> SendHeld {
    match seal(driver, member, group).await {
        LocationSeal::Deferred(held_by) => held_by,
        LocationSeal::Sealed { .. } => panic!("the seal was made"),
    }
}

/// The location records `member` stores for `group`.
async fn locations(member: &CircleMember, group: &GroupId) -> Vec<FanoutProbe> {
    (member.session().location_records_for_test(group).await).expect("the store is read")
}

/// The packets waiting in `member`'s hand-off, leaving the purges.
fn offered(member: &CircleMember) -> Vec<(u32, Packet)> {
    (waiting(member).into_iter())
        .filter_map(|(slot, packet)| Some((slot, packet?)))
        .collect()
}

/// The format byte of `packet`, opened under a key `member` stores for
/// `group`.
fn format_of(member: &CircleMember, group: &GroupId, packet: &Packet) -> Option<u8> {
    (rows(member, group).iter())
        .find_map(|row| open(&MeshKey::derive(&row.2), packet))
        .map(|parts| parts.format as u8)
}

/// Where the driver's clock must be set for `event` to expire `before_ms`
/// later.
fn before_expiry(event: &Event, before_ms: u64) -> u64 {
    let expires_ms = event.tags.expiration().expect("an expiration").as_secs() * 1_000;
    expires_ms - before_ms - ManualClock::ORIGIN
}

/// A location sealed for the mesh alone has a record like any other and
/// calls no relay; its send answers `MeshOnly`, leaves one packet of format
/// `0x01` for the mesh, ends the record and calls no relay either. A peer's
/// mesh drive takes the packet in as it takes any location. The relay
/// path's own seal, made after it, is sent as ever and goes out as `0x02`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_sealed_for_the_mesh_alone_reaches_a_peer_by_mesh_and_no_relay() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let peer = &others[0];
    mesh_on(&admin).await;
    mesh_on(peer).await;
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let driver = over(&relays, &clock, &FULL);

    let event = sealed(&driver, &admin, &group).await;
    let stored = locations(&admin, &group).await;
    assert!(
        stored.len() == 1 && stored[0].event_id == event.id,
        "a location sealed for the mesh alone has no record of its own"
    );
    assert!(
        relays.calls() == 0 && offered(&admin).is_empty(),
        "the seal called a relay, or reached the mesh before its send-time check"
    );

    let wraps = admin.session().mesh_costs_for_test().1;
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &event).await,
            LocationPublish::MeshOnly
        ),
        "the send of a location sealed for the mesh alone did not say so"
    );
    assert!(
        relays.calls() == 0,
        "a location sealed for the mesh alone was handed to a relay"
    );
    let slot = admin
        .session()
        .mesh_slot_for_test(&group)
        .map(|slot| slot.0);
    let handed = offered(&admin);
    let [(at, packet)] = &handed[..] else {
        panic!("the send left no packet, or more than its own, for the mesh");
    };
    assert!(Some(*at) == slot && admin.session().mesh_costs_for_test().1 == wraps + 1);
    assert!(
        format_of(&admin, &group, packet) == Some(0x01) && Format::NeverBridged as u8 == 0x01,
        "a location sealed for the mesh alone went out as one a member may pass on to a relay"
    );
    assert!(
        locations(&admin, &group).await.is_empty(),
        "the send did not end its record"
    );

    // The record is gone: a second send of it is none, to a relay or the mesh.
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Ended
    ));
    assert!(relays.calls() == 0 && offered(&admin).is_empty());

    // A peer reads it off the mesh as it reads any location.
    let reader = WatchedRelays::default();
    let taken = over(&reader, &clock, &FULL)
        .mesh_drive(&peer.circle, vec![packet.clone()])
        .await;
    assert!(
        taken.read == [(packet.id(), true)] && has_fix(&taken.replayed, &admin, LATITUDE),
        "a peer's mesh drive did not take in a location sealed for the mesh alone"
    );
    assert!(stored_fix(peer, &group, &admin, LATITUDE).await && reader.calls() == 0);

    // The relay path's own seal carries no mark of the one before it.
    let (_, packet) = handed_off(&admin, &group).await;
    assert!(
        format_of(&admin, &group, &packet) == Some(0x02) && Format::Bridgeable as u8 == 0x02,
        "a location the relays were sent went out as one never passed on"
    );
}

/// A location sealed for the mesh alone is sent to no relay by anything
/// that follows: a relay drive while its record stands, its send from
/// another process — which answers `Superseded` and leaves nothing for the
/// mesh — a relay drive of that process, or its send after that.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_sealed_for_the_mesh_alone_is_sent_to_no_relay_by_any_later_call() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let driver = over(&relays, &clock, &FULL);
    let (first, second) = (
        sealed(&driver, &admin, &group).await,
        sealed(&driver, &admin, &group).await,
    );

    let _ = driver.resume(&admin.circle).await;
    assert!(
        locations(&admin, &group).await.len() == 2 && relays.calls() == 0,
        "a relay drive sent, or ended, a location whose own send was still to come"
    );

    // Another process: the mark went with the one that sealed.
    let admin = admin.reopen();
    assert!(
        admin.session().mesh_on_until_for_test() != 0,
        "premise: mesh is still on"
    );
    let _ = waiting(&admin);
    assert!(
        matches!(
            driver.publish_location(&admin.circle, &first).await,
            LocationPublish::Superseded
        ),
        "another process sent a location it did not seal"
    );
    assert!(relays.calls() == 0 && offered(&admin).is_empty());

    let _ = driver.resume(&admin.circle).await;
    assert!(
        locations(&admin, &group).await.is_empty(),
        "a drive kept a record a dead process left"
    );
    assert!(matches!(
        driver.publish_location(&admin.circle, &second).await,
        LocationPublish::Ended
    ));
    assert!(
        relays.calls() == 0 && offered(&admin).is_empty(),
        "a location sealed for the mesh alone reached a relay, or the mesh, from a process that \
         did not seal it"
    );
}

/// With mesh off nothing is sealed, and the engine is not asked: the answer
/// comes while another call holds it. So too once the deadline has passed
/// on the clock the seal is made on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_mesh_off_nothing_is_sealed_and_the_engine_is_not_asked() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let driver = over(&relays, &clock, &FULL);
    let nothing_sealed = |what: &'static str| {
        let (admin, driver, relays, group) = (&admin, &driver, &relays, &group);
        async move {
            let engine = admin.session().hold_session_for_test().await;
            let answered = (driver.seal_for_mesh(&admin.circle, group, &fix())).now_or_never();
            drop(engine);
            let Some(Ok(answered)) = answered else {
                panic!("{what}: the seal waited for the engine, or failed");
            };
            assert!(
                matches!(answered.seal, LocationSeal::Deferred(SendHeld::Nothing))
                    && answered.replayed.is_empty()
                    && answered.retry_after_ms.is_none(),
                "{what}: a seal for the mesh alone was not answered as not made"
            );
            assert!(
                locations(admin, group).await.is_empty() && relays.calls() == 0,
                "{what}: a location was sealed, or a relay called"
            );
        }
    };
    nothing_sealed("mesh never turned on").await;

    mesh_on(&admin).await;
    clock.set(wall_ms() + 2 * HOUR_MS - ManualClock::ORIGIN);
    nothing_sealed("the deadline passed").await;

    assert!(admin.session().mesh_off().await);
    clock.set(0);
    nothing_sealed("mesh turned off").await;
}

/// A commit of this device's that awaits its relays stays pending: the seal
/// is deferred as awaiting relays and nothing is sent — where the relay
/// path's seal would send the commit again. The next relay drive sends it,
/// and the seal after that is made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_awaiting_its_relays_defers_the_seal_and_is_not_sent_again() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
    let at = epoch(&admin, &group).await;
    let staged = through(&transport, &outbox, &clock, &FULL)
        .update_relays(&admin.circle, &group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("the change is staged");
    assert!(
        staged.status == EvolutionStatus::Unresolved,
        "premise: awaiting relays"
    );
    let (pending, before) = (
        staged_ref(&admin, &group).await,
        records_of(&admin, &group).await.len(),
    );
    assert!(pending.is_some() && before == 1 && transport.calls().len() == 1);

    // Long enough on that the relay is due the commit again: a relay drive
    // made now would send it.
    clock.set(HOUR_MS);
    let relays = WatchedRelays::default();
    assert!(
        held_by(&over(&relays, &clock, &FULL), &admin, &group).await == SendHeld::AwaitingRelays,
        "a seal behind a commit awaiting its relays was not deferred as awaiting them"
    );
    assert!(
        relays.calls() == 0 && transport.calls().is_empty(),
        "a seal for the mesh alone sent a pending commit again"
    );
    assert!(
        staged_ref(&admin, &group).await == pending
            && records_of(&admin, &group).await.len() == before
            && locations(&admin, &group).await.is_empty()
            && offered(&admin).is_empty(),
        "a seal for the mesh alone resolved the pending commit, or sealed behind it"
    );

    // The next relay drive sends the same commit and applies it; the seal
    // after it is made.
    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Accepted]);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        transport.calls().len() == 1
            && staged_ref(&admin, &group).await.is_none()
            && epoch(&admin, &group).await == at + 1,
        "the commit the seal left pending was not sent by the next relay drive"
    );
    let _ = sealed(&over(&relays, &clock, &FULL), &admin, &group).await;
    assert_eq!(relays.calls(), 0);
}

/// What holds the relay path's seal holds the seal for the mesh alone, with
/// the same answer: fetched input not yet taken in, a leave asked for, and a
/// disbanded circle. Nothing is sealed and no relay is called.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn what_holds_a_relay_seal_holds_a_seal_for_the_mesh_alone() {
    type Hold = for<'a> fn(&'a CircleMember, &'a GroupId) -> futures::future::BoxFuture<'a, ()>;
    let holds: [(&str, bool, SendHeld, Hold); 4] = [
        (
            "a fetched commit held unread",
            false,
            SendHeld::StoredInput,
            |member, group| {
                Box::pin(async move {
                    (member.session())
                        .hold_pager_commits_for_test(group, &[nostr::EventId::all_zeros()]);
                })
            },
        ),
        (
            "stored replay a live REQ holds",
            false,
            SendHeld::StoredInput,
            |member, group| {
                Box::pin(async move { member.session().hold_live_replay_for_test(group) })
            },
        ),
        (
            "a leave asked for",
            false,
            SendHeld::Leaving,
            |member, group| {
                Box::pin(async move {
                    let transport = ScriptedFanout::default();
                    transport.answer(ONE, [Answer::Silent]);
                    let (outbox, clock) = (Recorder::acking(true), ManualClock::at(0));
                    let left = through(&transport, &outbox, &clock, &FULL)
                        .leave(&member.circle, group, &member.keys.public_key())
                        .await
                        .expect("the leave is accepted");
                    assert!(left.status == LeaveStatus::Proposed, "premise: proposed");
                })
            },
        ),
        (
            "a disbanded circle",
            true,
            SendHeld::Disbanded,
            |admin, group| {
                Box::pin(async move {
                    let _ = disband(admin, group).await;
                })
            },
        ),
    ];
    for (what, by_admin, held, hold) in holds {
        let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
        let device = if by_admin { &admin } else { &others[0] };
        mesh_on(device).await;
        hold(device, &group).await;
        let _ = waiting(device);

        let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
        let driver = over(&relays, &clock, &FULL);
        assert!(
            held_by(&driver, device, &group).await == held,
            "{what} did not hold a seal for the mesh alone"
        );
        assert!(
            relays.calls() == 0
                && locations(device, &group).await.is_empty()
                && offered(device).is_empty(),
            "{what}: a location was sealed, or a relay called"
        );
        let by_relay = (driver.seal_location(&device.circle, &group, &fix()).await)
            .expect("the seal runs")
            .seal;
        assert!(
            matches!(by_relay, LocationSeal::Deferred(theirs) if theirs == held),
            "{what} holds the relay path's seal otherwise than the seal for the mesh alone"
        );
    }
}

/// The seal is made as a call that makes no commit, whatever its caller's
/// mode: an eviction that is due is left due and holds the seal. Nothing is
/// staged — not even to be undone — and no relay is called. The relay
/// path's seal, in the full mode, then makes the eviction.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_that_is_due_holds_the_seal_and_is_not_committed() {
    let fx = setup_circle(3, &[ONE]).await;
    let leave = leave_of(&fx, 1).await;
    let (admin, others, group) = split(fx);
    mesh_on(&admin).await;
    make_a_departure_due(&admin, &others[1], &group, &leave).await;

    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    for _ in 0..2 {
        wait_out_the_engine(&admin, &group).await;
        assert!(
            held_by(&over(&relays, &clock, &FULL), &admin, &group).await == SendHeld::DepartureDue,
            "a seal for the mesh alone with an eviction due was not answered as held by it"
        );
        assert!(staged_ref(&admin, &group).await.is_none());
    }
    assert!(
        newest_commit_row(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && locations(&admin, &group).await.is_empty()
            && relays.calls() == 0,
        "a seal for the mesh alone staged the eviction, sealed behind it, or called a relay"
    );

    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    wait_out_the_engine(&admin, &group).await;
    let made = through(&transport, &outbox, &clock, &FULL)
        .seal_location(&admin.circle, &group, &fix())
        .await
        .expect("the seal runs");
    assert!(
        matches!(made.seal, LocationSeal::Deferred(SendHeld::Nothing))
            && transport.calls().len() == 1,
        "control: the relay path's seal, in the full mode, makes the eviction"
    );
}

/// The seal calls no relay even when its hold hands back input a relay
/// plane left stranded: the stranded locations come back with the answer,
/// stored, and the location is sealed and sent to the mesh alone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_seal_for_the_mesh_alone_that_hands_back_stranded_input_calls_no_relay() {
    let (admin, others, group, _, _) = fixes_stranded_by_a_confirm(2).await;
    let admin = admin.reopen();
    mesh_on(&admin).await;
    assert!(
        held(admin.session(), &group).await.len() == 2,
        "premise: two locations are stranded"
    );
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let driver = over(&relays, &clock, &FULL);

    let outcome = (driver.seal_for_mesh(&admin.circle, &group, &fix()).await).expect("the seal");
    assert!(relays.calls() == 0, "the hand-back led to a relay call");
    assert!(
        has_fix(&outcome.replayed, &others[0], latitude_of(0))
            && has_fix(&outcome.replayed, &others[1], latitude_of(1)),
        "the seal did not hand back what its hold released"
    );
    assert!(stored_fix(&admin, &group, &others[1], latitude_of(1)).await);
    assert!(held(admin.session(), &group).await.is_empty());
    let LocationSeal::Sealed { event, .. } = outcome.seal else {
        panic!("the seal behind the hand-back was not made");
    };
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::MeshOnly
    ));
    assert!(relays.calls() == 0 && offered(&admin).len() == 1);
}

/// A proposal the seal's hold is handed back with no record — the store
/// refused the write — is not sent by the seal and is not lost: the next
/// relay drive sends it, once, to its own circle's relays.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_proposal_the_seal_could_write_no_record_for_is_sent_by_the_next_relay_drive() {
    let (device, admin_a, admin_b, peer) = (
        CircleMember::new(),
        CircleMember::new(),
        CircleMember::new(),
        CircleMember::new(),
    );
    let group_a = found_circle(&admin_a, &[&device, &peer], &[ONE]).await;
    let group_b = found_circle(&admin_b, &[&device], &[TWO]).await;
    let (minted, proposal) = a_leave_minted_again(&device, &admin_a, &peer, &group_a, ONE).await;
    mesh_on(&device).await;

    let (db, key) = mls_db(device.dir.path());
    set_fanout_write_fault_naming_for_test(&db, &key, ONE, true).expect("arm");
    device.session().strand_effects_for_test(minted);
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let _ = sealed(&over(&relays, &clock, &FULL), &device, &group_b).await;
    set_fanout_write_fault_naming_for_test(&db, &key, ONE, false).expect("disarm");
    assert!(
        relays.calls() == 0,
        "a seal for the mesh alone sent what its hold handed back"
    );
    assert!(
        (records_of(&device, &group_a).await.iter()).all(|record| record.event_id != proposal),
        "premise: no record was written for the proposal"
    );

    let (transport, outbox) = (ScriptedFanout::default(), Recorder::acking(true));
    transport.answer(ONE, [Answer::Accepted; 8]);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&device.circle)
        .await;
    let sent: Vec<_> = (outbox.handed().into_iter())
        .filter(|(event, _)| event.id == proposal)
        .collect();
    assert!(
        sent.len() == 1 && sent[0].1 == [ONE],
        "a proposal the seal could not record was lost, sent twice, or sent to another \
         circle's relays"
    );
}

/// T-SEC-7 for a location sealed for the mesh alone: one its send-time
/// check refuses — the circle left its epoch, a commit of this device's is
/// staged, this device was removed, the event expired — and one whose
/// circle fell silent while the check ran leave nothing for the mesh. No
/// relay is called in any of them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_send_of_a_location_sealed_for_the_mesh_alone_reaches_neither_carrier() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let (relays, clock) = (WatchedRelays::default(), ManualClock::at(0));
    let driver = over(&relays, &clock, &FULL);
    let untouched = |device: &CircleMember, wraps: usize, what: &str| {
        assert!(
            offered(device).is_empty() && device.session().mesh_costs_for_test().1 == wraps,
            "a send answered {what} left a packet for the mesh",
        );
        assert!(relays.calls() == 0, "a send answered {what} called a relay");
    };
    let wraps = admin.session().mesh_costs_for_test().1;

    // Superseded: the circle left the epoch the location was sealed at.
    let event = sealed(&driver, &admin, &group).await;
    let (commit, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    (admin.session().confirm_published(pending).await).expect("applied");
    (member
        .session()
        .process_event_settled_for_test(&commit)
        .await)
        .expect("applied");
    let _ = waiting(&admin);
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Superseded
    ));
    untouched(&admin, wraps, "Superseded");

    // Superseded: a commit of this device's is staged.
    let event = sealed(&driver, &admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE]).await;
    let _ = waiting(&admin);
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Superseded
    ));
    untouched(&admin, wraps, "Superseded");
    (admin.session().publish_failed(pending).await).expect("rolled back");

    // Expired: a send begun now could not end before the event does.
    let event = sealed(&driver, &admin, &group).await;
    let _ = waiting(&admin);
    clock.set(before_expiry(&event, LOCATION_SEND_MS));
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Expired
    ));
    untouched(&admin, wraps, "Expired");
    clock.set(0);

    // The circle fell silent while the send checked: the send is made — to
    // no relay, as ever — and nothing is left for the mesh.
    let event = sealed(&driver, &admin, &group).await;
    let _ = waiting(&admin);
    (admin.session()).after_send_check_for_test(SessionManager::mesh_sharing_stopped);
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::MeshOnly
    ));
    untouched(&admin, wraps, "for a circle silenced while it checked");

    // Superseded: this device was removed from the circle since the seal.
    let member_wraps = member.session().mesh_costs_for_test().1;
    let event = sealed(&driver, member, &group).await;
    let removal = (admin.circle)
        .remove_members_for_test(&group, &[member.pubkey_hex()])
        .await
        .expect("the admin removes the member");
    (member
        .session()
        .process_event_settled_for_test(&removal)
        .await)
        .expect("the removal is taken in");
    let _ = waiting(member);
    assert!(matches!(
        driver.publish_location(&member.circle, &event).await,
        LocationPublish::Superseded
    ));
    untouched(member, member_wraps, "Superseded, for a removed member");
}
