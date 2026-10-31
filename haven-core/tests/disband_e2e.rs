//! An admin's disband, seen by a member: the circle reads as disbanded from
//! MDK's tombstone every time — after a crash that lost the announcement
//! too — nothing is sealed for it or asked of a relay for it any more, its
//! former members are neither kept current nor treated as removed, and the
//! circle's other planes go on.
//!
//! Real MDK engines over `SQLCipher` stores and scripted relays: nothing is
//! dialled, and the only real time paid is the engine's own announced
//! deadline for settling the disband (`docs/MDK_UPSTREAM_TRACKER.md`
//! T-CONVERGENCE-CLOCK).

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use std::sync::Arc;

use haven_core::circle::types::CircleEngineState;
use haven_core::circle::DirectoryTier;
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{DriveMode, LocationSeal, SendHeld};
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore};
use haven_core::relay::scripted_relay::ScriptedRelay;
use haven_core::relay::RelayManager;
use helpers::drive::{disband, ngid, take_in_disband, through, ManualClock, Recorder};
use helpers::stranded::split;
use helpers::{found_circle, setup_circle, CircleMember};

const FULL: DriveMode = DriveMode::Full;

/// What the driver's seal answers for `member`'s circle `group`.
async fn seal(member: &CircleMember, group: &GroupId) -> Result<(), SendHeld> {
    let (transport, outbox, clock) = (
        ScriptedFanout::default(),
        Recorder::acking(true),
        ManualClock::at(0),
    );
    match through(&transport, &outbox, &clock, &FULL)
        .seal_location(&member.circle, group, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("the seal runs")
        .seal
    {
        LocationSeal::Sealed { .. } => Ok(()),
        LocationSeal::Deferred(held) => Err(held),
    }
}

async fn state_of(member: &CircleMember, group: &GroupId) -> CircleEngineState {
    member
        .circle
        .get_circle(group)
        .await
        .expect("read")
        .expect("the circle is listed")
        .engine_state
}

/// A member that took the disband in and died before Haven saw the
/// announcement: at the next open the circle reads as disbanded, nothing is
/// sealed for it, its routing id is not asked of any relay, a drive sends
/// nothing, and the notice can name who disbanded it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_crash_after_disband_before_projection_still_stops_routing_on_next_open() {
    let relay = ScriptedRelay::start();
    let fx = setup_circle(2, &[relay.url()]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let commit = disband(&admin, &group).await;
    // The engine alone takes it in: nothing of Haven's sees the batch.
    take_in_disband(&member, &group, &commit).await;
    let member = member.reopen();

    assert_eq!(
        state_of(&member, &group).await,
        CircleEngineState::Disbanded
    );
    assert_eq!(seal(&member, &group).await, Err(SendHeld::Disbanded));
    assert_eq!(
        member.circle.disbanded_by(&group).await,
        Some(admin.pubkey_hex()),
        "the notice cannot name who disbanded the circle",
    );
    let core = LiveSyncCore::new_local(
        Arc::clone(&member.circle),
        member.keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[CircleSpec {
            group_id_hex: hex::encode(ngid(&member, &group).await),
            relays: vec![relay.url().to_string()],
        }],
        &[],
    )
    .await
    .expect("the engine starts");
    let _ = core.follow_routing().await;
    assert_eq!(
        core.pool_subscription_count().await,
        0,
        "a disbanded circle's routing id is still asked of a relay",
    );
    let _ = core.stop().await;
    let transport = ScriptedFanout::default();
    transport.answer(relay.url(), [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&member.circle)
        .await;
    assert!(
        transport.calls().is_empty() && outbox.handed().is_empty(),
        "a drive sent something for a disbanded circle",
    );
}

/// A disband takes everyone out at once, and is no removal: the member's
/// directory neither keeps the admin current for ever nor deletes them as a
/// person who removed the member — they age out as after a leave.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disband_commit_is_not_presented_as_member_removals() {
    let relay = ScriptedRelay::start();
    let fx = setup_circle(2, &[relay.url()]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let now = chrono::Utc::now().timestamp();
    let tier = |member: &CircleMember, pubkey: &str| {
        member
            .circle
            .ranked_directory_members(now)
            .expect("the directory")
            .into_iter()
            .find(|entry| entry.pubkey_hex == pubkey)
            .map(|entry| entry.tier)
    };
    assert_eq!(
        tier(&member, &admin.pubkey_hex()),
        Some(DirectoryTier::Current),
        "premise"
    );
    let commit = disband(&admin, &group).await;
    take_in_disband(&member, &group, &commit).await;

    member
        .circle
        .reconcile_member_directory(haven_core::circle::DirectoryReconcile::Rewrite, now)
        .await
        .expect("the directory is reconciled");

    assert_eq!(
        tier(&member, &admin.pubkey_hex()),
        Some(DirectoryTier::Recent),
        "a disband's former member was kept current, or deleted as a removal",
    );
    assert!(
        member.session().peek_change_notes(&group).is_empty(),
        "the disband was told as a change of the circle's members",
    );
}

/// A disband touches its circle alone: the member's other circle, with the
/// same admin, is sealed for and followed as before.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn inbound_disband_stops_send_and_receive_for_that_circle_only() {
    let (relay, elsewhere) = (ScriptedRelay::start(), ScriptedRelay::start());
    let fx = setup_circle(2, &[relay.url()]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let other = found_circle(&admin, &[&member], &[elsewhere.url()]).await;
    let commit = disband(&admin, &group).await;
    take_in_disband(&member, &group, &commit).await;

    assert_eq!(seal(&member, &group).await, Err(SendHeld::Disbanded));
    assert_eq!(
        seal(&member, &other).await,
        Ok(()),
        "the other circle's sends stopped"
    );
    assert_eq!(state_of(&member, &other).await, CircleEngineState::Live);
    let core = LiveSyncCore::new_local(
        Arc::clone(&member.circle),
        member.keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[
            CircleSpec {
                group_id_hex: hex::encode(ngid(&member, &group).await),
                relays: vec![relay.url().to_string()],
            },
            CircleSpec {
                group_id_hex: hex::encode(ngid(&member, &other).await),
                relays: vec![elsewhere.url().to_string()],
            },
        ],
        &[],
    )
    .await
    .expect("the engine starts");
    let _ = core.follow_routing().await;
    assert_eq!(
        core.pool_subscription_count().await,
        1,
        "the disbanded circle is still followed, or the other one is not",
    );
    assert_eq!(
        core.relays_in_pool_for_test().await,
        [nostr::RelayUrl::parse(elsewhere.url()).expect("a relay url")],
        "the REQ left is not the other circle's",
    );
    let _ = core.stop().await;
}

/// A drive under way when the disband's settle deletes the record it is
/// sending: the answer is not written back, nothing more is sent, the relay
/// layer no longer refuses the event, and the pass is not reported as an
/// error.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_fanout_driver_tolerates_rows_deleted_by_disband() {
    const ONE: &str = "wss://one.disband-canary2c5e.example.com";
    const TWO: &str = "wss://two.disband-canary2c5e.example.com";
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let removed = through(&transport, &outbox, &clock, &FULL)
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("the removal is made");
    assert_eq!(
        removed.status,
        haven_core::relay::fanout::EvolutionStatus::Confirmed,
        "premise: applied on ONE's acknowledgement, still owed to TWO"
    );
    let commit = transport
        .calls()
        .into_iter()
        .find(|call| call.target == ONE)
        .map(|call| <nostr::Event as nostr::JsonUtil>::from_json(&call.payload).expect("event"));
    let admin = Arc::new(admin);
    // TWO is owed again later: the drive that sends to it parks there.
    clock.set(60 * 60 * 1_000);
    transport.park();
    let drive = {
        let (admin, transport, group) = (Arc::clone(&admin), Arc::clone(&transport), group.clone());
        let clock = clock.clone();
        tokio::spawn(async move {
            let outbox = Recorder::acking(true);
            let outcome = through(&transport, &outbox, &clock, &FULL)
                .resume(&admin.circle)
                .await;
            let _ = group;
            outcome.errored
        })
    };
    transport.parked().await;
    let _ = disband(&admin, &group).await;
    let sent_before = transport.call_count();
    transport.unpark();
    let errored = drive.await.expect("the drive joins");

    assert!(
        !errored,
        "a record the disband deleted made the pass an error"
    );
    assert_eq!(
        transport.call_count(),
        sent_before,
        "something more was sent"
    );
    assert!(
        admin
            .session()
            .fanout_ids_for_test(&group)
            .await
            .expect("read")
            .is_empty(),
        "the deleted record was written back",
    );
    if let Some(commit) = commit {
        assert!(
            !haven_core::relay::fanout::is_owned(&commit.id),
            "the relay layer still refuses the deleted record's event",
        );
    }
}

/// What Haven keeps of a disbanded circle that nothing can use any more —
/// the note that a Welcome is owed, a location's record — is cleared at the
/// next open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_disbanded_circles_leftovers_are_cleared_at_the_next_open() {
    const ONE: &str = "wss://one.disband-canary2c5e.example.com";
    let founder = CircleMember::new();
    let invitee = CircleMember::new();
    let inbox = vec!["wss://inbox.disband-canary2c5e.example.com".to_string()];
    let package = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            invitee.session(),
            &invitee.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox,
        nip65_relays: Vec::new(),
        nip65_write_relays: Vec::new(),
    };
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(false);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let created = driver
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![package],
            &haven_core::circle::CircleConfig::new("Disbanded").with_relays(vec![ONE.to_string()]),
        )
        .await
        .expect("the circle is created");
    let group = created.circle.mls_group_id;
    assert_eq!(
        seal(&founder, &group).await,
        Ok(()),
        "premise: a location's record stands"
    );
    assert!(
        !founder.session().peek_change_notes(&group).is_empty()
            && !founder
                .session()
                .location_records_for_test(&group)
                .await
                .expect("read")
                .is_empty(),
        "premise: a Welcome is owed and a location is recorded",
    );
    let _ = disband(&founder, &group).await;

    let founder = founder.reopen();
    founder.circle.recover_owed_outputs().await;

    assert!(
        founder.session().peek_change_notes(&group).is_empty(),
        "a disbanded circle is still told a Welcome is owed",
    );
    assert!(
        founder
            .session()
            .location_records_for_test(&group)
            .await
            .expect("read")
            .is_empty(),
        "a disbanded circle's location record outlived the open",
    );
}
