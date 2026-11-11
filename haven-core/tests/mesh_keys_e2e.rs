//! The mesh key ring over real engines and the real circle store (plan
//! §4.2, T-SEC-6).
//!
//! A circle's packet keys are kept for the epoch it stands on and the five
//! before it, in memory and in the `mesh_keys` table of `circles-v2.db`, only
//! while mesh is on. Every test reads the table itself, through a connection
//! of its own, beside what the ring answers.
//!
//! `mesh::manager`'s unit tests script the engine; these run MDK's. A commit
//! another member made is applied once the engine's own quiescence window for
//! it has closed (`process_event_settled_for_test`): the engine's clock cannot
//! be set, so that wait is the engine's, never a margin chosen here.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::mesh::packet::{open, MeshKey};
use haven_core::nostr::mls::types::GroupId;
use haven_core::nostr::mls::{DEFAULT_MAX_PAST_EPOCHS, MESH_ON_MAX_MS};
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::{DriveMode, LocationPublish};
use helpers::drive::{
    disband, epoch, ngid, take_in_disband, through, ManualClock, Recorder, HOUR_MS,
};
use helpers::mesh::{
    epochs, handed_off, mesh_on, row_count, row_epochs, rows, sealed, stored_deadline, waiting,
    wall_ms,
};
use helpers::removals::store;
use helpers::stranded::{co_admin, split, stage_relays, staged};
use helpers::{found_circle, setup_circle, CircleMember};
use nostr::{Event, JsonUtil as _};

const ONE: &str = "wss://one.mesh-keys.example.com";
const TWO: &str = "wss://two.mesh-keys.example.com";
const THREE: &str = "wss://three.mesh-keys.example.com";

/// `by` changes the circle's relays and applies the change — one epoch on —
/// and hands back the commit. Each `round` asks for a set the last did not.
async fn commits(by: &CircleMember, group: &GroupId, round: u64) -> Event {
    let relays: &[&str] = if round.is_multiple_of(2) {
        &[ONE, TWO]
    } else {
        &[ONE]
    };
    let (commit, pending) = stage_relays(by.session(), group, relays).await;
    (by.session().confirm_published(pending).await).expect("the commit is applied");
    commit
}

async fn follows(member: &CircleMember, commit: &Event) {
    (member
        .session()
        .process_event_settled_for_test(commit)
        .await)
        .expect("the member applies the commit");
}

/// The window: the epoch a circle stands on and the engine's past epochs.
fn window() -> u64 {
    u64::try_from(DEFAULT_MAX_PAST_EPOCHS).expect("small") + 1
}

/// Whether `reader`'s ring opens `packet` as `event`, and under which epoch's
/// key.
fn opens(
    reader: &CircleMember,
    packet: &haven_core::mesh::packet::Packet,
    event: &Event,
) -> Option<u64> {
    let (_, epoch, opened) = reader.session().mesh_open_for_test(packet)?;
    assert!(
        opened.as_json() == event.as_json(),
        "a packet opened as another event than the one handed off",
    );
    Some(epoch)
}

/// T-SEC-6: keys are pruned in step with the engine's retention. After the
/// sixth epoch change the oldest epoch's key is gone from memory and from the
/// table, on the device that made the commits and on the one that took them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn keys_are_pruned_in_step_with_the_engines_window_in_memory_and_in_the_table() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let (first, routing) = (epoch(&admin, &group).await, ngid(&admin, &group).await);
    assert!(epochs(&admin, &group) == [first] && row_epochs(&admin, &group) == [first]);
    assert!(epochs(member, &group) == [first] && row_epochs(member, &group) == [first]);

    for round in 0..window() {
        let commit = commits(&admin, &group, round).await;
        follows(member, &commit).await;
        let kept: Vec<u64> = (first..=first + round + 1).rev().take(6).collect();
        for device in [&admin, member] {
            assert!(
                epochs(device, &group) == kept && row_epochs(device, &group) == kept,
                "a device's keys are not those of its engine's window",
            );
        }
        // What is at rest is the epoch's exporter secret: two engines agree
        // on every row, and each row carries the circle's routing id.
        assert!(
            rows(&admin, &group) == rows(member, &group),
            "two devices' engines disagree on a stored key"
        );
        assert!(rows(&admin, &group).iter().all(|row| row.1 == routing));
    }
    assert!(
        !epochs(&admin, &group).contains(&first) && !row_epochs(&admin, &group).contains(&first),
        "the sixth epoch change left the oldest key behind",
    );

    // The newest row is the secret the packet key is derived from.
    let (event, packet) = handed_off(&admin, &group).await;
    let newest = rows(&admin, &group)[0];
    let parts = open(&MeshKey::derive(&newest.2), &packet).expect("the newest row's key opens it");
    assert!(haven_core::mesh::event::rebuild(&parts, &newest.1)
        .is_some_and(|rebuilt| rebuilt.as_json() == event.as_json()));
    assert!(open(&MeshKey::derive(&rows(&admin, &group)[1].2), &packet).is_none());
}

/// T-SEC-6: while a commit is staged MDK exports the staged epoch's secret.
/// It is not installed until the commit is confirmed, and a rollback leaves
/// nothing of it in memory or in the table.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_staged_epochs_key_is_installed_at_its_confirm_and_never_at_a_rollback() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let stood = epoch(&admin, &group).await;
    let before = rows(&admin, &group);
    assert!(
        row_epochs(&admin, &group) == [stood],
        "premise: one epoch's key is stored"
    );

    // Every circle's key is brought in line again while the commit is
    // staged, as an engine batch naming the circle would.
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    mesh_on(&admin).await;
    assert!(
        epochs(&admin, &group) == [stood] && rows(&admin, &group) == before,
        "a staged commit's key was installed before its confirm",
    );

    (admin.session().publish_failed(pending).await).expect("the commit is rolled back");
    mesh_on(&admin).await;
    assert!(
        epochs(&admin, &group) == [stood] && rows(&admin, &group) == before,
        "a rolled-back commit left a key behind",
    );

    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    mesh_on(&admin).await;
    assert!(epochs(&admin, &group) == [stood] && rows(&admin, &group) == before);
    (admin.session().confirm_published(pending).await).expect("the commit is applied");
    assert!(
        epochs(&admin, &group) == [stood + 1, stood],
        "the confirm did not install the new epoch's key in memory"
    );
    let after = rows(&admin, &group);
    assert!(
        row_epochs(&admin, &group) == [stood + 1, stood]
            && after[1] == before[0]
            && after[0].2 != before[0].2,
        "the confirm did not install the new epoch's key beside the last one",
    );
}

/// T-SEC-6: a restart keeps the keys of the retained epochs. The process
/// that reopens the stores can still open what a peer an epoch behind sealed,
/// and still wraps under the epoch it stands on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_keeps_the_keys_of_the_retained_epochs() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let first = epoch(&admin, &group).await;
    let commit = commits(&admin, &group, 0).await;
    follows(member, &commit).await;
    // The admin moves on; the member, which has not seen it, seals.
    let ahead = commits(&admin, &group, 1).await;
    let (behind, from_behind) = handed_off(member, &group).await;
    let kept = rows(&admin, &group);
    assert!(
        row_epochs(&admin, &group) == [first + 2, first + 1, first],
        "premise: three epochs' keys are stored"
    );

    let admin = admin.reopen();
    assert!(
        epochs(&admin, &group) == [first + 2, first + 1, first] && rows(&admin, &group) == kept,
        "a restart lost a retained epoch's key, or rewrote one",
    );
    assert!(admin.session().mesh_on_until_for_test() != 0);
    assert!(
        opens(&admin, &from_behind, &behind) == Some(first + 1),
        "after a restart a peer one epoch behind is no longer read",
    );
    let (event, packet) = handed_off(&admin, &group).await;
    assert!(
        opens(&admin, &packet, &event) == Some(first + 2),
        "after a restart the device no longer opens what it wraps"
    );
    assert!(
        member.session().mesh_open_for_test(&packet).is_none(),
        "premise: the member has not reached the epoch the packet was sealed at",
    );
    follows(member, &ahead).await;
    assert!(
        opens(member, &packet, &event) == Some(first + 2),
        "a member that caught up does not open the packet"
    );
    // An outsider's key opens nothing.
    assert!(open(&MeshKey::derive(&[0x5a; 32]), &packet).is_none());
}

/// T-SEC-6, Q-7: at the open a deadline that has passed, or none at all, is
/// mesh off, and the keys an earlier process left are deleted; one further
/// ahead than twelve hours is brought back to twelve.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_open_deletes_stored_keys_unless_a_deadline_still_stands() {
    let set_deadline = |member: &CircleMember, to: Option<u64>| {
        let changed = to.map_or_else(
            || store(member).execute("DELETE FROM user_settings WHERE key = 'mesh_on_until'", []),
            |to| {
                store(member).execute(
                    "UPDATE user_settings SET value = ?1 WHERE key = 'mesh_on_until'",
                    [to.to_string()],
                )
            },
        );
        assert!(
            changed.expect("the store is written") == 1,
            "premise: a deadline was stored"
        );
    };
    for (deadline, on) in [
        (Some(wall_ms() - 1), false),
        (None, false),
        (Some(wall_ms() + 30 * 24 * HOUR_MS), true),
    ] {
        let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
        mesh_on(&admin).await;
        let _ = commits(&admin, &group, 0).await;
        assert!(
            row_count(&admin) == 2,
            "premise: two epochs' keys are stored"
        );
        set_deadline(&admin, deadline);

        let admin = admin.reopen();
        let until = admin.session().mesh_on_until_for_test();
        if on {
            assert!(epochs(&admin, &group).len() == 2 && row_count(&admin) == 2);
            assert!(
                until > wall_ms() && until <= wall_ms() + MESH_ON_MAX_MS,
                "a stored deadline kept mesh on for longer than twelve hours",
            );
            assert!(
                stored_deadline(&admin) == Some(until.to_string()),
                "the deadline brought back to twelve hours was not stored"
            );
        } else {
            assert!(
                epochs(&admin, &group).is_empty() && row_count(&admin) == 0 && until == 0,
                "a process that opened with mesh off kept the keys an earlier one stored",
            );
            assert!(stored_deadline(&admin).is_none());
            // And derives none from here on.
            let _ = commits(&admin, &group, 1).await;
            assert!(row_count(&admin) == 0 && admin.session().mesh_costs_for_test().0 == 0);
        }
    }
}

/// T-SEC-6, finding 3: one key an epoch number. Two admins commit from one
/// epoch and each applies its own: two branches at one height, each with its
/// own key. Two other members are handed the two commits in opposite orders,
/// so one of them stands on the branch the circle does not keep when the
/// other commit arrives. That device's key is replaced, in memory and in the
/// table, and every key behind it is dropped; no device keeps the abandoned
/// branch's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_branch_reselected_at_the_same_height_replaces_the_key_and_drops_the_past() {
    let fx = setup_circle(4, &[ONE]).await;
    co_admin(&fx).await;
    let group = fx.group.clone();
    let [one, two, third, fourth] = &fx.members[..] else {
        panic!("four members");
    };
    for device in &fx.members {
        mesh_on(device).await;
    }
    let commit = commits(one, &group, 1).await;
    for device in [two, third, fourth] {
        follows(device, &commit).await;
    }
    let source = epoch(one, &group).await;
    let fork = source + 1;

    let (first, pending_one) = stage_relays(one.session(), &group, &[ONE, TWO]).await;
    let (second, pending_two) = stage_relays(two.session(), &group, &[ONE, THREE]).await;
    (one.session().confirm_published(pending_one).await).expect("applied");
    (two.session().confirm_published(pending_two).await).expect("applied");
    assert!(
        rows(one, &group)[0].0 == fork
            && rows(two, &group)[0].0 == fork
            && rows(one, &group)[0].2 != rows(two, &group)[0].2,
        "premise: two branches at one height, each with its own key",
    );
    let (_, from_one) = handed_off(one, &group).await;
    let (_, from_two) = handed_off(two, &group).await;
    let reads = |reader: &CircleMember| {
        (
            reader.session().mesh_open_for_test(&from_one).is_some(),
            reader.session().mesh_open_for_test(&from_two).is_some(),
        )
    };

    // Each stands on the branch it was handed first, with that branch's key
    // and the keys behind it.
    follows(third, &first).await;
    follows(fourth, &second).await;
    assert!(reads(third) == (true, false) && reads(fourth) == (false, true));
    assert!(
        epochs(third, &group) == [fork, source, source - 1],
        "premise: a member on the first branch it was handed, with the keys behind it"
    );
    assert!(
        epochs(fourth, &group) == [fork, source, source - 1],
        "premise: a member on the first branch it was handed, with the keys behind it"
    );

    // Each is handed the other branch: the circle keeps one of the two.
    follows(third, &second).await;
    follows(fourth, &first).await;
    let relays = |member: &CircleMember| {
        let (member, group) = (member.circle.clone(), group.clone());
        async move { member.session().group_relays(&group).await.expect("relays") }
    };
    assert!(
        relays(third).await == relays(fourth).await
            && epoch(third, &group).await == fork
            && epoch(fourth, &group).await == fork,
        "premise: both settled on one branch, at the height of the fork",
    );
    let kept_ones = relays(third).await == relays(one).await;
    let (switched, stayed) = if kept_ones {
        (fourth, third)
    } else {
        (third, fourth)
    };
    let kept = if kept_ones {
        (true, false)
    } else {
        (false, true)
    };

    assert!(
        reads(switched) == kept && reads(stayed) == kept,
        "a device holds the abandoned branch's key, or lacks the kept branch's",
    );
    assert!(
        epochs(switched, &group) == [fork] && row_epochs(switched, &group) == [fork],
        "the device that switched branches kept keys from behind the fork",
    );
    assert!(
        epochs(stayed, &group).first() == Some(&fork)
            && row_epochs(stayed, &group) == epochs(stayed, &group),
    );
    assert!(
        rows(switched, &group)[0] == rows(stayed, &group)[0]
            && rows(switched, &group)[0] == rows(if kept_ones { one } else { two }, &group)[0],
        "two devices on one branch hold two keys for one epoch",
    );
    // And wraps under the kept branch's key from here on.
    let (event, packet) = handed_off(switched, &group).await;
    assert!(
        opens(stayed, &packet, &event) == Some(fork),
        "the device that switched does not wrap under the kept branch's key"
    );
}

/// T-SEC-6, F-3: a circle's routing id can change at an epoch, and a packet
/// carries none. Each key records the routing id of its epoch, so a packet
/// sealed before the rotation is rebuilt under the id it was signed with.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_routing_id_rotation_is_recorded_with_the_epoch_it_took_effect_at() {
    use cgka_traits::app_components::{
        encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
    };
    use haven_core::nostr::mls::types::{AppComponentData, SendIntent};

    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let (before, old, new) = (
        epoch(&admin, &group).await,
        ngid(&admin, &group).await,
        [0xc7; 32],
    );
    let (sealed_before, packet_before) = handed_off(member, &group).await;

    // As another client's admin would: Haven never rotates a routing id.
    let rotation = (admin.session())
        .send(SendIntent::UpdateAppComponents {
            group_id: group.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: encode_nostr_routing_v1(
                    &NostrRoutingV1::new(new, vec![ONE.to_string()]).expect("a routing state"),
                )
                .expect("the component encodes"),
            }],
        })
        .await
        .expect("the rotation is staged");
    let (commit, pending) = staged(&rotation);
    (admin.session().confirm_published(pending).await).expect("the rotation is applied");
    follows(member, &commit).await;

    for device in [&admin, member] {
        assert!(
            device.session().mesh_key_epochs_for_test(&group) == [(before + 1, new), (before, old)],
            "a key does not carry the routing id of its own epoch",
        );
        let stored: Vec<(u64, [u8; 32])> = rows(device, &group)
            .iter()
            .map(|row| (row.0, row.1))
            .collect();
        assert!(
            stored == [(before + 1, new), (before, old)],
            "a stored key does not carry the routing id of its own epoch"
        );
    }
    // Sealed under the old id, opened under the past key, rebuilt with the
    // id recorded for that key: the signature holds.
    assert!(
        opens(&admin, &packet_before, &sealed_before) == Some(before),
        "a packet sealed before the rotation was not rebuilt under the id it was signed with"
    );
    assert!(sealed_before
        .tags
        .iter()
        .any(|tag| tag.as_slice().get(1) == Some(&hex::encode(old))));
}

/// T-SEC-6: a member three commits behind is handed all three before its
/// engine applies any. MDK exports the epoch a circle stands on and no
/// other, so whatever the engine crossed in one call has no key: the ring
/// ends on the engine's epoch, holds no epoch the table does not, and none
/// the engine did not stand on between two calls.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_member_that_crosses_several_epochs_ends_on_the_engines_key() {
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let first = epoch(member, &group).await;
    let mut ahead = Vec::new();
    for round in 0..3 {
        ahead.push(commits(&admin, &group, round).await);
    }
    let derived = member.session().mesh_costs_for_test().0;
    for commit in &ahead {
        let _ = member
            .session()
            .process_event(commit)
            .await
            .expect("the ingest runs");
    }
    let _ =
        (member.session().settle_receive_for_test(&group).await).expect("the commits are applied");
    assert!(
        epoch(member, &group).await == first + 3,
        "premise: the member caught up"
    );

    let held = epochs(member, &group);
    let installed = member.session().mesh_costs_for_test().0 - derived;
    assert!(
        held.first() == Some(&(first + 3)) && held.last() == Some(&first),
        "the member's newest key is not its engine's, or its oldest was dropped inside the window",
    );
    assert!(
        held.len() == installed + 1 && row_epochs(member, &group) == held,
        "a key is held that no engine call ended on, or the table and the ring differ",
    );
    let (event, packet) = handed_off(&admin, &group).await;
    assert!(
        opens(member, &packet, &event) == Some(first + 3),
        "the member does not open a packet sealed at the epoch it caught up to"
    );
}

/// T-SEC-6: mesh off — never asked for, a deadline that is not ahead of the
/// clock, turned off, or a deadline that passes — means nothing derived,
/// nothing stored, and what was stored deleted. A deadline further ahead than
/// twelve hours is twelve hours.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_mesh_off_nothing_is_derived_or_stored_and_what_was_stored_is_deleted() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    let untouched = |member: &CircleMember| {
        epochs(member, &group).is_empty()
            && row_count(member) == 0
            && stored_deadline(member).is_none()
    };

    // Never turned on: epochs change, a location is sent, and nothing is
    // derived, sealed for the mesh or written.
    let _ = commits(&admin, &group, 0).await;
    let (transport, outbox) = (ScriptedFanout::default(), Recorder::acking(true));
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &DriveMode::Full);
    let event = sealed(&driver, &admin, &group).await;
    assert!(matches!(
        driver.publish_location(&admin.circle, &event).await,
        LocationPublish::Sent(Ok(_))
    ));
    assert!(untouched(&admin) && waiting(&admin).is_empty());
    // One write, at the open: the delete of whatever an earlier process left.
    assert!(
        admin.session().mesh_costs_for_test() == (0, 0, 1),
        "with mesh never on, a key was derived, a packet sealed, or a row written"
    );

    // A deadline at or behind the clock is no deadline.
    for until in [0, wall_ms() - 1] {
        assert!(!admin.session().mesh_on_until(until).await);
        assert!(untouched(&admin) && admin.session().mesh_costs_for_test().0 == 0);
    }

    // Further ahead than twelve hours: twelve hours, in memory and stored.
    assert!(admin.session().mesh_on_until(u64::MAX).await);
    let until = admin.session().mesh_on_until_for_test();
    assert!(until > wall_ms() && until <= wall_ms() + MESH_ON_MAX_MS);
    assert!(
        stored_deadline(&admin) == Some(until.to_string()),
        "the deadline kept is not the deadline stored"
    );
    let _ = commits(&admin, &group, 1).await;
    assert!(row_count(&admin) == 2 && epochs(&admin, &group).len() == 2);
    let (_, _) = handed_off(&admin, &group).await;

    // Turned off: every key and the deadline deleted, the slot emptied.
    let slot = admin
        .session()
        .mesh_slot_for_test(&group)
        .expect("a slot")
        .0;
    let (_, _) = handed_off(&admin, &group).await;
    assert!(admin.session().mesh_off().await);
    assert!(untouched(&admin) && waiting(&admin) == [(slot, None)]);
    let _ = commits(&admin, &group, 2).await;
    assert!(
        untouched(&admin),
        "an epoch change with mesh off derived or stored a key"
    );

    // On again, and the deadline passes: the first engine batch after it
    // deletes every key.
    assert!(admin.session().mesh_on_until(wall_ms() + HOUR_MS).await);
    assert!(
        row_count(&admin) == 1,
        "premise: mesh on again stored the circle's key"
    );
    admin
        .session()
        .set_legacy_clock_for_test(wall_ms() + HOUR_MS + 1);
    let _ = commits(&admin, &group, 3).await;
    assert!(untouched(&admin), "keys outlived their deadline");
    assert!(
        admin.session().mesh_on_until_for_test() == 0,
        "a deadline that passed still stands"
    );
}

/// T-SEC-6: a circle that is left, disbanded or forgotten leaves no row, and
/// no other circle's rows go with it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn leaving_disbanding_or_forgetting_a_circle_leaves_no_row_of_it() {
    // Left: the member's device ends the circle.
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    let other = found_circle(member, &[], &[TWO]).await;
    mesh_on(member).await;
    assert!(row_epochs(member, &group).len() == 1 && row_epochs(member, &other).len() == 1);
    let slot = member
        .session()
        .mesh_slot_for_test(&group)
        .expect("a slot")
        .0;
    let _ = handed_off(member, &group).await;
    let _ = handed_off(member, &group).await;
    let _ = waiting(member);
    (member.circle.complete_leave(&group, 1_800_000_000).await).expect("the circle is left");
    assert!(
        rows(member, &group).is_empty() && epochs(member, &group).is_empty(),
        "a left circle's keys were kept",
    );
    assert!(
        waiting(member).contains(&(slot, None)),
        "a left circle's slot was not emptied"
    );
    assert!(row_epochs(member, &other).len() == 1 && epochs(member, &other).len() == 1);
    // Nothing brings them back: asked for again, mesh keys no left circle.
    mesh_on(member).await;
    assert!(rows(member, &group).is_empty() && row_count(member) == 1);

    // Forgotten in the engine alone, as an abandoned create is.
    mesh_on(&admin).await;
    assert!(
        row_epochs(&admin, &group).len() == 1,
        "premise: the admin's key is stored"
    );
    (admin.session().forget_group_local(&group).await).expect("the group is forgotten");
    assert!(rows(&admin, &group).is_empty() && epochs(&admin, &group).is_empty());

    // Disbanded: the admin's device, and a member's that took the disband in.
    let (admin, others, group) = split(setup_circle(2, &[ONE]).await);
    let member = &others[0];
    mesh_on(&admin).await;
    mesh_on(member).await;
    let commit = disband(&admin, &group).await;
    take_in_disband(member, &group, &commit).await;
    for device in [&admin, member] {
        device.circle.recover_owed_outputs().await;
        assert!(
            rows(device, &group).is_empty()
                && epochs(device, &group).is_empty()
                && row_count(device) == 0,
            "a disbanded circle's keys were kept",
        );
    }
}

/// Identity delete: the logout wipe deletes `circles-v2.db` with its sidecars
/// and destroys its keyring key (`wipe_all_mls_state` in the bridge). The
/// keys and the deadline live in that store and nowhere else: with it gone,
/// a process that opens over what is left — the MLS store, the circle still
/// live in it — restores no key, and mesh is off.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_keys_and_the_deadline_live_in_the_circle_store_alone() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let _ = commits(&admin, &group, 0).await;
    assert!(
        row_count(&admin) == 2,
        "premise: two epochs' keys are stored"
    );

    let CircleMember { circle, keys, dir } = admin;
    drop(std::sync::Arc::try_unwrap(circle).unwrap_or_else(|_| panic!("the manager is shared")));
    let store = dir.path().join(haven_core::circle::CIRCLES_DB_FILENAME);
    for sidecar in ["", "-wal", "-shm", "-journal"] {
        let mut file = store.clone().into_os_string();
        file.push(sidecar);
        let _ = std::fs::remove_file(file);
    }
    let circle = std::sync::Arc::new(
        haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
            .expect("the stores reopen"),
    );
    let admin = CircleMember { circle, keys, dir };
    assert!(
        admin.session().epoch(&group).await.is_ok(),
        "premise: the circle is still live in the MLS store",
    );
    assert!(
        epochs(&admin, &group).is_empty()
            && row_count(&admin) == 0
            && stored_deadline(&admin).is_none()
            && admin.session().mesh_on_until_for_test() == 0,
        "a mesh key or the deadline outlived the circle store",
    );
}

/// A deadline that passes while no circle does anything ends the keys all
/// the same: the maintenance tick's expiry sweep, which holds the session
/// and reads its clock, deletes them from memory and from the table with no
/// engine batch to see the deadline pass. A tick before it changes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deadline_that_passes_with_no_engine_batch_ends_the_keys_at_the_maintenance_tick() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let _ = commits(&admin, &group, 0).await;
    let now = wall_ms();
    let tick = || async {
        (admin
            .session()
            .sweep_expired_key_packages(now / 1_000)
            .await)
            .expect("the sweep runs");
    };

    admin.session().set_legacy_clock_for_test(now + HOUR_MS / 2);
    tick().await;
    assert!(
        epochs(&admin, &group).len() == 2 && row_count(&admin) == 2,
        "a tick before the deadline cost a key"
    );

    admin.session().set_legacy_clock_for_test(now + 2 * HOUR_MS);
    tick().await;
    assert!(
        epochs(&admin, &group).is_empty() && admin.session().mesh_on_until_for_test() == 0,
        "a deadline that passed with no engine batch left the keys in memory"
    );
    assert!(
        row_count(&admin) == 0 && stored_deadline(&admin).is_none(),
        "a deadline that passed with no engine batch left the keys in the table"
    );
}

/// A stored key whose circle has no row — the circle was left and the delete
/// of its keys did not land — is not restored at the open, and is deleted;
/// the keys of a circle that stands are restored beside it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_open_restores_no_key_of_a_circle_whose_row_is_gone() {
    let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
    mesh_on(&admin).await;
    let gone = GroupId::new(vec![0x6e; 32]);
    let written = store(&admin).execute(
        "INSERT INTO mesh_keys (mls_group_id, epoch, routing_id, secret)
         SELECT ?1, epoch, routing_id, secret FROM mesh_keys",
        [gone.as_slice()],
    );
    assert!(
        written.expect("the store is written") == 1 && row_count(&admin) == 2,
        "premise: a key is stored for a circle with no row"
    );

    let admin = admin.reopen();
    assert!(
        epochs(&admin, &gone).is_empty() && rows(&admin, &gone).is_empty(),
        "the open restored, or left stored, the key of a circle whose row is gone"
    );
    assert!(epochs(&admin, &group).len() == 1 && row_epochs(&admin, &group).len() == 1);
}
