//! A removal the user asked for that was set aside unmade is asked for again
//! by the first full drive once its circle is caught up (decision 180,
//! automatic): for the members it named who are still listed, only while
//! this device is an admin, and bounded as MDK's own re-issue is. Made, its
//! note is cleared; already made by somebody else, it is said so; past its
//! bounds it is left for the user.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::nostr::mls::types::{GroupId, RequeueOutcome, SendIntent};
use haven_core::nostr::mls::{max_rewind_commits, ChangeNote, MAX_REQUEUE_ATTEMPTS};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{DriveMode, Publishing, ResumeOutcome};
use helpers::drive::{roster, through, within, ManualClock, Recorder};
use helpers::removals::{confirmed, held, make_admins, store};
use helpers::stranded::{split, staged};
use helpers::{setup_circle, CircleMember};

const ONE: &str = "wss://one.requeue-canary51af.example.com";
const FULL: DriveMode = DriveMode::Full;

/// A circle of `size` whose admin's removal of the member at `named` was set
/// aside unmade at an open, as a queued change is: the note stands and the
/// member is kept. The admin's session asks for it again on its own, as the
/// automatic posture the owner may still choose would ([`requeuing`]).
async fn a_removal_set_aside(
    size: usize,
    named: usize,
) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let fx = setup_circle(size, &[ONE]).await;
    let (admin, others, group) = split(fx);
    admin
        .session()
        .queue_removal_intent_for_test(&group, &[others[named].pubkey_hex()])
        .await
        .expect("queued");
    let admin = requeuing(admin.reopen());
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedRemovalDropped),
        "premise: the removal was set aside unmade",
    );
    (admin, others, group)
}

/// `member`, whose session asks for its removals set aside again on its own
/// (decision 180, automatic): the posture the owner may still choose; what
/// ships is "offered" (decision 233,
/// `a_removal_set_aside_is_held_and_noted_and_never_asked_for_again`).
fn requeuing(member: CircleMember) -> CircleMember {
    member.session().requeue_for_test();
    member
}

async fn drive(driver: &Publishing<'_, ScriptedFanout>, admin: &CircleMember) -> ResumeOutcome {
    driver.resume(&admin.circle).await
}

/// A self-update of `member`'s, applied: one epoch further.
async fn an_epoch_further(member: &CircleMember, group: &GroupId) {
    let (_, pending) = staged(
        &member
            .session()
            .send(SendIntent::SelfUpdate {
                group_id: group.clone(),
            })
            .await
            .expect("a self-update"),
    );
    member
        .session()
        .confirm_published(pending)
        .await
        .expect("applied");
}

/// Caught up, the first full drive asks for the removal again for the
/// member still listed and makes it: the member is gone and the note is
/// cleared — not retyped as a change that could no longer be made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_asked_for_again_and_made_once_the_circle_is_caught_up() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    let early = drive(&driver, &admin).await;
    assert!(
        early.requeued.is_empty() && roster(&admin, &group).await.contains(&target),
        "a removal set aside was asked for again before its circle was caught up",
    );
    admin.session().mark_caught_up_for_test(&group);
    let made = drive(&driver, &admin).await;
    let notes = admin.session().peek_change_notes(&group);
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.group_id == group && requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target)
            && !notes.contains(&ChangeNote::QueuedRemovalDropped)
            && !notes.contains(&ChangeNote::QueuedChangeDropped),
        "a removal asked for again was not made, or its note was kept or retyped",
    );
}

/// What ships ("offered", decision 233): a removal set aside unmade is never
/// asked for again by a drive, however often it runs once its circle is
/// caught up. The member it named stays listed and holds the circle, and the
/// note stands, until the user removes them again from the notice.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_held_and_noted_and_never_asked_for_again() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let target = others[0].pubkey_hex();
    admin
        .session()
        .queue_removal_intent_for_test(&group, std::slice::from_ref(&target))
        .await
        .expect("queued");
    let admin = admin.reopen();
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    for _ in 0..=MAX_REQUEUE_ATTEMPTS {
        let outcome = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
        assert!(
            outcome.requeued.is_empty() && transport.calls().is_empty(),
            "a removal set aside was asked for again by a drive",
        );
    }
    assert!(
        roster(&admin, &group).await.contains(&target)
            && held(&admin) == [target.clone()]
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "the member a removal set aside named was not held, or its note did not stand",
    );
}

/// One whose member somebody else has already removed is not asked for
/// again: the commit that took the member out ends the hold and takes the
/// note back as it is applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_whose_member_is_gone_is_already_made() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    // The member is removed meanwhile (here by the admin itself, the
    // ordinary way).
    let (_, pending) = staged(
        &admin
            .session()
            .remove_members(&group, std::slice::from_ref(&target))
            .await
            .expect("removed"),
    );
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("applied");
    assert!(
        held(&admin).is_empty()
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "the commit that took the member out did not end the hold, or left the note",
    );
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let outcome = drive(&driver, &admin).await;
    assert!(
        outcome.requeued.is_empty() && transport.calls().is_empty(),
        "a removal whose member was already gone was asked for again",
    );

    // A batch lost with its process: the store still holds the member, whom
    // the applied roster no longer lists. The drive reads it so, and says so.
    store(&admin)
        .execute_batch(&format!(
            "INSERT OR REPLACE INTO removal_targets (mls_group_id, member, set_aside_epoch, asks) \
             VALUES (x'{}', x'{target}', 0, 0); \
             UPDATE commit_notes SET untold = untold | 1024 WHERE mls_group_id = x'{}';",
            hex::encode(group.as_slice()),
            hex::encode(group.as_slice()),
        ))
        .expect("the target is planted");
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedRemovalDropped),
        "premise: the note stands again",
    );
    let read = drive(&driver, &admin).await;
    assert!(
        read.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::AlreadyMade)
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped)
            && held(&admin).is_empty()
            && transport.calls().is_empty(),
        "a removal whose member the applied roster no longer lists was asked for again, or \
         not said made",
    );
}

/// Asked for again as often as MDK's own re-issue is, it is not asked for
/// again: typed abandoned, its note left for the user.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_asked_for_again_as_often_as_it_may_be_is_abandoned() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    admin.session().mark_caught_up_for_test(&group);
    // Every relay refuses: each ask is undone, and the member stays.
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    for _ in 0..MAX_REQUEUE_ATTEMPTS {
        let asked = drive(&driver, &admin).await;
        assert!(
            asked
                .requeued
                .iter()
                .any(|requeued| requeued.outcome == RequeueOutcome::Undone),
            "premise: the removal was asked for again and undone",
        );
    }
    let last = drive(&driver, &admin).await;
    assert!(
        last.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Abandoned)
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex())
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a removal asked for again more often than MDK re-issues was asked again, or its \
         note was not left for the user",
    );
}

/// Once the circle has moved past MDK's rewind horizon since the removal
/// was set aside, it is not asked for again: its member stays held, and the
/// note stays for the user.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_expires_past_the_rewind_horizon() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let first = drive(&driver, &admin).await;
    assert!(
        first
            .requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Undone),
        "premise: asked for once",
    );
    for _ in 0..max_rewind_commits() {
        an_epoch_further(&admin, &group).await;
    }
    let edge = drive(&driver, &admin).await;
    assert!(
        edge.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Undone),
        "a removal was not asked for again at the edge of the horizon from its set-aside",
    );
    an_epoch_further(&admin, &group).await;
    let late = drive(&driver, &admin).await;
    assert!(
        late.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Expired)
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex())
            && held(&admin) == [others[0].pubkey_hex()]
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a removal was asked for again past the rewind horizon, or its member stopped being \
         held, or its note was not left",
    );
}

/// A removal asked for again whose relays answer later is made by a later
/// drive: its confirm ends the hold and takes the note back, without
/// retyping it as a change that could no longer be made, and nothing is
/// asked for again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_asked_for_again_and_made_later_is_not_retyped() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let asked = drive(&driver, &admin).await;
    assert!(
        asked
            .requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Pending),
        "premise: asked for again, its relays not yet answering",
    );
    clock.set(haven_core::relay::fanout::RETRY_MAX_MS + 1_000);
    let _ = drive(&driver, &admin).await;
    let after = drive(&driver, &admin).await;
    let notes = admin.session().peek_change_notes(&group);
    assert!(
        !roster(&admin, &group)
            .await
            .contains(&others[0].pubkey_hex())
            && after.requeued.is_empty()
            && held(&admin).is_empty()
            && !notes.contains(&ChangeNote::QueuedRemovalDropped)
            && !notes.contains(&ChangeNote::QueuedChangeDropped),
        "a removal asked for again and made later was not cleared, or was retyped as a change \
         that could no longer be made",
    );
}

/// While the commit of its last ask is pending, a removal is not asked for
/// again: its ask is driven, and the asks it may still have are not spent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_is_not_asked_for_again_while_its_last_ask_is_pending() {
    let (admin, _others, group) = a_removal_set_aside(3, 0).await;
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let asked = drive(&driver, &admin).await;
    assert!(
        asked
            .requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Pending),
        "premise: asked for once",
    );
    for _ in 0..=MAX_REQUEUE_ATTEMPTS {
        let again = drive(&driver, &admin).await;
        assert!(
            again.requeued.is_empty(),
            "a removal was asked for again while its last ask was pending",
        );
    }
}

/// A device that is no longer an admin asks for nothing again: the removal
/// is left for the user, its member kept, and none of its asks spent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_not_asked_for_again_by_a_device_no_longer_an_admin() {
    let (admin, others, group) = a_removal_set_aside(4, 1).await;
    let (heir, target) = (&others[0], others[1].pubkey_hex());
    for admins in [
        vec![
            admin.keys.public_key().to_bytes(),
            heir.keys.public_key().to_bytes(),
        ],
        vec![heir.keys.public_key().to_bytes()],
    ] {
        let (_, pending) = staged(
            &admin
                .session()
                .update_admin_policy(&group, &admins)
                .await
                .expect("the admins change"),
        );
        admin
            .session()
            .confirm_published(pending)
            .await
            .expect("applied");
    }
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let outcome = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        outcome.requeued.is_empty()
            && roster(&admin, &group).await.contains(&target)
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a device no longer an admin asked for a removal again, or dropped its note",
    );
}

/// A re-queue count that cannot be read asks for nothing — the bound cannot
/// be checked — and what is logged of it names nothing; once it reads again
/// the removal is asked for and made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_whose_requeue_count_cannot_be_read_is_not_asked_for_again() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    admin.session().mark_caught_up_for_test(&group);
    // A count stored as text: read as an error.
    store(&admin)
        .execute(
            "UPDATE removal_targets SET asks = 'unread' WHERE mls_group_id = ?1",
            [group.as_slice()],
        )
        .expect("the count is spoiled");
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let mut unread = None;
    let lines = helpers::capture_haven_log(Box::pin(async {
        unread = Some(drive(&driver, &admin).await);
    }))
    .await;
    assert!(
        unread.is_some_and(|unread| unread.requeued.is_empty())
            && transport.calls().is_empty()
            && roster(&admin, &group).await.contains(&target),
        "a removal was asked for again though its re-queue count could not be read",
    );
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        lines
            .iter()
            .any(|line| line.message.contains("a removal's targets were not read")),
        "premise: the failure is logged",
    );
    helpers::assert_no_needles(
        &lines,
        &[
            &hex::encode(group.as_slice()),
            &target,
            &admin.pubkey_hex(),
            "requeue-canary51af",
        ],
    );
    store(&admin)
        .execute(
            "UPDATE removal_targets SET asks = 0 WHERE mls_group_id = ?1",
            [group.as_slice()],
        )
        .expect("the count reads again");
    let read = drive(&driver, &admin).await;
    assert!(
        read.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "a removal whose re-queue count reads again was not asked for and made",
    );
}

/// A co-admin removes the member a removal set aside named and invites them
/// back, and this device applies both in one catch-up with no send between:
/// the member the circle chose to keep is not removed again, and the hold
/// ended with the commit that took them out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_not_asked_for_again_once_its_member_was_removed_and_invited_back() {
    let (admin, others, group) = a_removal_set_aside(3, 1).await;
    let (co, member) = (&others[0], &others[1]);
    make_admins(&admin, &[co, member], &group, &[&admin, co]).await;
    let removal = confirmed(
        co,
        &co.session()
            .remove_members(&group, &[member.pubkey_hex()])
            .await
            .expect("the co-admin removes the member"),
    )
    .await;
    let package =
        helpers::create_key_package_event(member.session(), &member.keys, &[ONE.to_string()]).await;
    let invite = confirmed(
        co,
        &co.session()
            .add_members(
                &group,
                vec![
                    haven_core::nostr::mls::SessionManager::key_package_from_event(&package)
                        .expect("it parses"),
                ],
            )
            .await
            .expect("the co-admin invites the member back"),
    )
    .await;
    for event in [&removal, &invite] {
        admin
            .session()
            .process_event_settled_for_test(event)
            .await
            .expect("applied");
    }
    assert!(
        roster(&admin, &group).await.contains(&member.pubkey_hex()),
        "premise: the member is back on the roster",
    );
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let outcome = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        outcome.requeued.is_empty()
            && roster(&admin, &group).await.contains(&member.pubkey_hex())
            && held(&admin).is_empty()
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a member removed and invited back was removed again, or still holds the circle",
    );
}

/// While another commit of this device's is staged, a removal set aside is
/// not asked for: nothing is queued, and no ask is spent — once that commit
/// is resolved the removal is asked for and made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_not_asked_for_beside_another_staged_commit() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    admin.session().mark_caught_up_for_test(&group);
    let _ = admin
        .session()
        .update_relays_staging(&group, vec![ONE.to_string()], 0)
        .await
        .expect("a relay change is staged");
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    for _ in 0..=MAX_REQUEUE_ATTEMPTS {
        let beside = drive(&driver, &admin).await;
        assert!(
            beside.requeued.is_empty()
                && admin
                    .session()
                    .queued_intent_count_for_test(&group)
                    .await
                    .expect("read")
                    == 0
                && roster(&admin, &group).await.contains(&target),
            "a removal was asked for beside another staged commit, or left queued",
        );
    }
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(haven_core::relay::fanout::RETRY_MAX_MS + 1_000);
    let _ = drive(&driver, &admin).await;
    let made = drive(&driver, &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "a removal held back beside another commit spent its asks, or was not made after",
    );
}

/// A drive without the room to ask spends nothing: however many such drives
/// pass, the removal is not abandoned, and the first drive with room makes
/// it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_without_room_to_ask_spends_no_ask() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    for _ in 0..=MAX_REQUEUE_ATTEMPTS {
        let starved = drive(&within(&transport, &outbox, &clock, &FULL, 0), &admin).await;
        assert!(
            starved.requeued.is_empty() && transport.calls().is_empty(),
            "a drive without room asked for a removal, or reported one",
        );
    }
    let made = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "drives without room spent the removal's asks",
    );
}

/// Two removals set aside in one circle keep their own counts: one asked
/// for as often as it may be does not spend the other's asks.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_removals_set_aside_in_one_circle_keep_their_own_counts() {
    let (admin, others, group) = a_removal_set_aside(4, 0).await;
    let (first, second) = (others[0].pubkey_hex(), others[1].pubkey_hex());
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    for _ in 0..MAX_REQUEUE_ATTEMPTS {
        let _ = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    }
    admin
        .session()
        .queue_removal_intent_for_test(&group, std::slice::from_ref(&second))
        .await
        .expect("queued");
    let admin = requeuing(admin.reopen());
    admin.session().mark_caught_up_for_test(&group);
    assert!(
        held(&admin) == {
            let mut both = vec![first.clone(), second.clone()];
            both.sort();
            both
        },
        "premise: both removals are set aside",
    );
    transport.answer(ONE, [Answer::Accepted]);
    let made = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&second)
            && roster(&admin, &group).await.contains(&first)
            && held(&admin) == [first.clone()],
        "a removal asked for as often as it may be spent another's asks, or was asked again",
    );
}

/// In a circle this device is leaving, a removal set aside is not asked for:
/// the engine would refuse it behind the leave.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_not_asked_for_in_a_circle_being_left() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    store(&admin)
        .execute(
            "INSERT INTO user_settings (key, value) VALUES (?1, '1700000000')",
            [format!("leave_intent_v1:{}", hex::encode(group.as_slice()))],
        )
        .expect("the leave intent is written");
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let outcome = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        outcome.requeued.is_empty()
            && transport.calls().is_empty()
            && roster(&admin, &group)
                .await
                .contains(&others[0].pubkey_hex()),
        "a removal was asked for in a circle being left",
    );
}

/// A reorg that undoes the commit that took a member out brings the member
/// back as one the removal set aside names: they hold the circle again, its
/// note is said again, and the removal is asked for and made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reorg_that_brings_back_a_member_a_removal_named_holds_and_asks_again() {
    let (admin, others, group) = a_removal_set_aside(5, 2).await;
    let member = others[2].pubkey_hex();
    let (b, c, bystander) = (&others[0], &others[1], &others[3]);
    make_admins(
        &admin,
        &[b, c, &others[2], bystander],
        &group,
        &[&admin, b, c],
    )
    .await;
    // At equal depth and priority the branch whose committer sorts lower
    // wins (MDK `convergence.rs` 138-146): the loser removes the member, the
    // winner removes the bystander.
    let (loser, winner) = if b.keys.public_key().to_bytes() > c.keys.public_key().to_bytes() {
        (b, c)
    } else {
        (c, b)
    };
    let taken_out = confirmed(
        loser,
        &loser
            .session()
            .remove_members(&group, std::slice::from_ref(&member))
            .await
            .expect("one co-admin removes the member"),
    )
    .await;
    let rival = confirmed(
        winner,
        &winner
            .session()
            .remove_members(&group, &[bystander.pubkey_hex()])
            .await
            .expect("the other removes the bystander"),
    )
    .await;
    admin
        .session()
        .process_event_settled_for_test(&taken_out)
        .await
        .expect("applied");
    assert!(
        held(&admin).is_empty()
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "premise: the commit that took the member out ended the hold",
    );
    let _ = admin.session().process_event_settled_for_test(&rival).await;
    let session = admin.session();
    let _ = session.advance_for_receive(&group).await;
    while let Some(after) = session.receive_retick_after(&group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(&group).await;
    }
    assert!(
        roster(&admin, &group).await.contains(&member)
            && !roster(&admin, &group)
                .await
                .contains(&bystander.pubkey_hex()),
        "premise: the reorg undid the member's removal",
    );
    assert!(
        held(&admin) == [member.clone()]
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a member a reorg brought back does not hold the circle, or its note was not said again",
    );
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let made = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&member),
        "the removal of a member a reorg brought back was not asked for again",
    );
}

/// A contested branch: this device's own commit at an epoch loses to a
/// co-admin's removal of the member a removal set aside named, at that epoch,
/// and their invitation back at the next. Measured at this pin, MDK adopts
/// the two in two passes — the invitation's envelope opens only once the
/// removal is applied — and the first announces both the removal and the
/// withdrawal of this device's commit, which brings back every member taken
/// out with their asks spent; the one-pass shape, which announces no removal
/// at all, is held by `a_pass_of_several_commits_spends_every_held_targets_asks`.
/// Either way the member the circle chose to keep is not removed: the hold and
/// the note stay for the user, and the re-queue says it is abandoned
/// (decision 227).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_contested_branch_does_not_remove_a_member_invited_back() {
    let (admin, others, group) = a_removal_set_aside(3, 1).await;
    let (co, member) = (&others[0], &others[1]);
    make_admins(&admin, &[co, member], &group, &[&admin, co]).await;
    // This device's own commit, at the epoch both branches start from.
    an_epoch_further(&admin, &group).await;
    let removal = confirmed(
        co,
        &co.session()
            .remove_members(&group, &[member.pubkey_hex()])
            .await
            .expect("the co-admin removes the member"),
    )
    .await;
    let package =
        helpers::create_key_package_event(member.session(), &member.keys, &[ONE.to_string()]).await;
    let invite = confirmed(
        co,
        &co.session()
            .add_members(
                &group,
                vec![
                    haven_core::nostr::mls::SessionManager::key_package_from_event(&package)
                        .expect("it parses"),
                ],
            )
            .await
            .expect("the co-admin invites the member back"),
    )
    .await;
    // Both arrive before any pass runs.
    for event in [&removal, &invite] {
        let _ = admin.session().process_event(event).await;
    }
    let session = admin.session();
    let _ = session.advance_for_receive(&group).await;
    while let Some(after) = session.receive_retick_after(&group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(&group).await;
    }
    assert!(
        roster(&admin, &group).await.contains(&member.pubkey_hex())
            && roster(&admin, &group).await == roster(co, &group).await,
        "premise: this device adopted the co-admin's branch, with the member back",
    );
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let outcome = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        outcome
            .requeued
            .iter()
            .all(|requeued| requeued.outcome == RequeueOutcome::Abandoned)
            && !outcome.requeued.is_empty()
            && transport.calls().is_empty()
            && roster(&admin, &group).await.contains(&member.pubkey_hex())
            && held(&admin) == [member.pubkey_hex()]
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a member removed and invited back inside one pass was removed again, or the hold \
         and its note were not kept for the user",
    );
}

/// This device's OWN removal loses: its re-queued removal of a member is
/// made here, keyed to its commit, while a co-admin who never saw it removes
/// the same member at that epoch and invites them back at the next. This
/// device adopts the co-admin's branch — measured at this pin in two passes,
/// the invitation's envelope opening only once the removal is applied
/// (`a_member_brought_back_by_the_pass_that_spends_is_spent_with_the_rest`
/// holds the one-pass shape, which MDK announces as a net diff naming
/// nobody). The first brings the member back keyed to the withdrawn commit,
/// its ask intact; the second applies the invitation, whose `MemberAdded`
/// spends it (decision 230). The member the circle chose to keep is not
/// removed again: the hold and the note stay for the user, and the re-queue
/// says it is abandoned.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_own_removal_that_loses_to_a_removal_and_an_invite_back_is_not_made_again() {
    let (admin, others, group) = a_removal_set_aside(3, 1).await;
    let (co, member) = (&others[0], &others[1]);
    make_admins(&admin, &[co, member], &group, &[&admin, co]).await;
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let made = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&member.pubkey_hex()),
        "premise: this device's own removal is made, here alone",
    );
    transport.calls();
    let removal = confirmed(
        co,
        &co.session()
            .remove_members(&group, &[member.pubkey_hex()])
            .await
            .expect("the co-admin removes the member"),
    )
    .await;
    let package =
        helpers::create_key_package_event(member.session(), &member.keys, &[ONE.to_string()]).await;
    let invite = confirmed(
        co,
        &co.session()
            .add_members(
                &group,
                vec![
                    haven_core::nostr::mls::SessionManager::key_package_from_event(&package)
                        .expect("it parses"),
                ],
            )
            .await
            .expect("the co-admin invites the member back"),
    )
    .await;
    for event in [&removal, &invite] {
        let _ = admin.session().process_event(event).await;
    }
    let session = admin.session();
    let _ = session.advance_for_receive(&group).await;
    while let Some(after) = session.receive_retick_after(&group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(&group).await;
    }
    assert!(
        roster(&admin, &group).await.contains(&member.pubkey_hex())
            && roster(&admin, &group).await == roster(co, &group).await,
        "premise: this device adopted the co-admin's branch, with the member back",
    );
    admin.session().mark_caught_up_for_test(&group);
    assert_eq!(
        held(&admin),
        [member.pubkey_hex()],
        "the member was not held for the user"
    );
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedRemovalDropped),
        "the note was not kept for the user",
    );
    let outcome = drive(&through(&transport, &outbox, &clock, &FULL), &admin).await;
    assert_eq!(
        outcome
            .requeued
            .iter()
            .map(|requeued| requeued.outcome)
            .collect::<Vec<_>>(),
        [RequeueOutcome::Abandoned],
        "the re-queue of a member the circle invited back was not said to be abandoned",
    );
    assert!(
        transport.calls().is_empty() && roster(&admin, &group).await.contains(&member.pubkey_hex()),
        "a member the circle invited back was removed again by this device's own lost removal",
    );
    assert!(
        outcome
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.outcome == haven_core::nostr::mls::types::WithdrawnOutcome::Abandoned)
            && admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ChangeWithdrawn),
        "the lost removal was handed to MDK's re-issue, or the user was not told it was withdrawn",
    );
}

/// While its circle holds received input the engine has not resolved — here
/// a peer's commit, buffered and not yet taken by a pass — a removal set
/// aside is not asked for: the ask would be made from an epoch the circle
/// may be leaving. Once the input is resolved, it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_not_asked_for_while_its_circle_has_input_unresolved() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let (target, peer) = (others[0].pubkey_hex(), &others[1]);
    let (commit, pending) = staged(
        &peer
            .session()
            .send(SendIntent::SelfUpdate {
                group_id: group.clone(),
            })
            .await
            .expect("a peer's self-update"),
    );
    peer.session()
        .confirm_published(pending)
        .await
        .expect("applied");
    let _ = admin.session().process_event(&commit).await;
    assert!(
        admin.session().has_pending_inputs_for_test(&group).await,
        "premise: the peer's commit is buffered, unresolved",
    );
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let unresolved = drive(&driver, &admin).await;
    assert!(
        unresolved.requeued.is_empty() && roster(&admin, &group).await.contains(&target),
        "a removal set aside was asked for while its circle had input unresolved",
    );
    let session = admin.session();
    while session.has_pending_inputs_for_test(&group).await {
        if let Some(after) = session.receive_retick_after(&group).await {
            tokio::time::sleep(after).await;
        }
        let _ = session.advance_for_receive(&group).await;
    }
    let made = drive(&driver, &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "a removal set aside was not asked for once its circle's input was resolved",
    );
}

/// With a change of the group queued in its circle, a removal set aside is
/// not asked for: the engine would queue it behind that change. Once the
/// queue is clear, it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_is_not_asked_for_while_its_circle_has_a_change_queued() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    let admins = admin
        .session()
        .admin_pubkeys(&group)
        .await
        .expect("the admins");
    admin
        .session()
        .queue_admin_policy_intent_for_test(
            &group,
            haven_core::nostr::mls::SessionManager::admin_policy_payload_for_test(&admins)
                .expect("payload"),
        )
        .await
        .expect("a change is queued");
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let queued = drive(&driver, &admin).await;
    assert!(
        queued.requeued.is_empty() && roster(&admin, &group).await.contains(&target),
        "a removal set aside was asked for behind a change queued in its circle",
    );
    admin
        .session()
        .take_back_queued_changes_for_test(&group)
        .await;
    let made = drive(&driver, &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "a removal set aside was not asked for once its circle's queue was clear",
    );
}

/// An ask is spent before the removal is asked for: a store that will not
/// count it asks nothing — never every drive again. Once it counts, the
/// removal is asked for and made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_whose_ask_cannot_be_counted_is_not_asked_for() {
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    admin.session().mark_caught_up_for_test(&group);
    store(&admin)
        .execute_batch(
            "CREATE TRIGGER no_count BEFORE UPDATE OF asks ON removal_targets \
             BEGIN SELECT RAISE(ABORT, 'refused'); END;",
        )
        .expect("the count is refused");
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    for _ in 0..=MAX_REQUEUE_ATTEMPTS {
        let refused = drive(&driver, &admin).await;
        assert!(
            refused.requeued.is_empty()
                && transport.calls().is_empty()
                && roster(&admin, &group).await.contains(&target),
            "a removal was asked for though its ask could not be counted",
        );
    }
    store(&admin)
        .execute_batch("DROP TRIGGER no_count;")
        .expect("the count is taken again");
    let made = drive(&driver, &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "a removal was not asked for once its ask could be counted",
    );
}

/// An ask under which nothing was staged — the commit could not be given its
/// record — is given back: however often that happens, the removal is not
/// abandoned, and is made once its record can be written.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ask_under_which_nothing_was_staged_is_given_back() {
    use haven_core::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
    let (admin, others, group) = a_removal_set_aside(3, 0).await;
    let target = others[0].pubkey_hex();
    admin.session().mark_caught_up_for_test(&group);
    let (db, key) = helpers::stranded::mls_db(admin.dir.path());
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    for _ in 0..MAX_REQUEUE_ATTEMPTS {
        let unrecorded = drive(&driver, &admin).await;
        assert!(
            unrecorded
                .requeued
                .iter()
                .any(|requeued| requeued.outcome == RequeueOutcome::NotMade)
                && roster(&admin, &group).await.contains(&target),
            "premise: the removal was asked for and nothing was staged under a record",
        );
    }
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    let made = drive(&driver, &admin).await;
    assert!(
        made.requeued
            .iter()
            .any(|requeued| requeued.outcome == RequeueOutcome::Made)
            && !roster(&admin, &group).await.contains(&target),
        "asks under which nothing was staged were spent: the removal was abandoned",
    );
}

/// In a process with no live plane — the flag-off configuration — a bridge
/// call whose caller says the app is in front of its user is the claim the
/// away-holds read, for as long as the call lasts: its seal is made though a
/// change of relays applied away holds the circle away from the foreground.
/// A call that claims nothing, made before and after, is held.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bridge_call_that_claims_the_foreground_is_the_claim_the_away_holds_read() {
    use haven_core::location::LocationMessage;
    use haven_core::relay::fanout::{Claimed, LocationSeal, SendHeld};

    let fx = setup_circle(3, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    awaits_foreground(&admin, &group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let fix = LocationMessage::new(51.5, -0.12);
    let seal = |foreground: bool| {
        let admin = &admin;
        let (transport, outbox, clock, group, fix) = (&transport, &outbox, &clock, &group, &fix);
        async move {
            let mode = Claimed::new(&admin.circle, foreground);
            Publishing {
                fanout: transport,
                publisher: outbox,
                clock: clock.as_ref(),
                deadline_ms: None,
                mode: &mode,
            }
            .seal_location(&admin.circle, group, fix)
            .await
            .expect("the seal is answered")
            .seal
        }
    };
    assert!(
        matches!(
            seal(false).await,
            LocationSeal::Deferred(SendHeld::AwaitsForeground)
        ),
        "premise: a call that claims nothing is held by the change of relays applied away",
    );
    assert!(
        matches!(seal(true).await, LocationSeal::Sealed { .. }),
        "a call the app in front of its user made was held as if it were away",
    );
    assert!(
        matches!(
            seal(false).await,
            LocationSeal::Deferred(SendHeld::AwaitsForeground)
        ),
        "a claim outlived the call that made it",
    );
}

/// Plants what a change of `group`'s relays finished away from the
/// foreground leaves (`ChangeNote::AwaitsForeground`): the one hold a
/// claimed foreground's call is not held by.
fn awaits_foreground(member: &CircleMember, group: &GroupId) {
    store(member)
        .execute(
            "INSERT INTO commit_notes (mls_group_id, untold) VALUES (?1, ?2)
             ON CONFLICT(mls_group_id) DO UPDATE SET untold = untold | ?2",
            rusqlite::params![group.as_slice(), ChangeNote::AwaitsForeground.bit()],
        )
        .expect("the note is planted");
}

/// A circle of three whose admin's removal of its first other member was set
/// aside unmade at an open, in the posture that ships: held and noted, never
/// asked for again on its own (decision 233).
async fn a_removal_held() -> (CircleMember, Vec<CircleMember>, GroupId) {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    admin
        .session()
        .queue_removal_intent_for_test(&group, &[others[0].pubkey_hex()])
        .await
        .expect("queued");
    let admin = admin.reopen();
    assert_eq!(
        held(&admin),
        [others[0].pubkey_hex()],
        "premise: the member the removal named is kept",
    );
    (admin, others, group)
}

/// `admin`'s seal of a fix for `group` by a bridge call whose caller says the
/// app is in front of its user, in a process with no live plane.
async fn foreground_seal(
    admin: &CircleMember,
    transport: &ScriptedFanout,
    group: &GroupId,
) -> haven_core::relay::fanout::LocationSeal {
    use haven_core::relay::fanout::Claimed;
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let mode = Claimed::new(&admin.circle, true);
    Publishing {
        fanout: transport,
        publisher: &outbox,
        clock: clock.as_ref(),
        deadline_ms: None,
        mode: &mode,
    }
    .seal_location(
        &admin.circle,
        group,
        &haven_core::location::LocationMessage::new(51.5, -0.12),
    )
    .await
    .expect("the seal is answered")
    .seal
}

/// Decision 238: while a member a removal set aside unmade named is still
/// listed, nothing is sealed for the circle by any call — a claimed
/// foreground's on the driver and on the legacy entry included — and the
/// hold is said typed and logs nothing that names the circle, the member or
/// the relay. Asked for again and made, the removal lets the next seal
/// through.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_holds_a_claimed_foregrounds_seal_until_it_is_made() {
    use haven_core::circle::CircleError;
    use haven_core::relay::fanout::{Claimed, LocationSeal, SendHeld};

    let (admin, others, group) = a_removal_held().await;
    let target = others[0].pubkey_hex();
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);

    let mut seal = None;
    let lines = helpers::capture_haven_log(Box::pin(async {
        seal = Some(foreground_seal(&admin, &transport, &group).await);
    }))
    .await;
    assert!(
        matches!(seal, Some(LocationSeal::Deferred(SendHeld::RemovalUnmade))),
        "a claimed foreground sealed a fix for a circle whose removed member is still listed",
    );
    let nostr_group_id = admin
        .circle
        .get_circle(&group)
        .await
        .expect("read")
        .expect("the circle")
        .circle
        .nostr_group_id;
    helpers::assert_no_needles(
        &lines,
        &[
            &hex::encode(group.as_slice()),
            &hex::encode(nostr_group_id),
            &target,
            &admin.pubkey_hex(),
            ONE,
            "requeue-canary51af",
        ],
    );
    {
        let _claim = Claimed::new(&admin.circle, true);
        let legacy = admin
            .circle
            .seal_location_for_test(
                &group,
                &haven_core::location::LocationMessage::new(51.5, -0.12),
            )
            .await;
        assert!(
            matches!(legacy, Err(CircleError::EngineHeld)),
            "the legacy entry sealed in a claimed foreground for a circle whose removed member \
             is still listed",
        );
    }
    assert!(transport.calls().is_empty(), "a held seal called a relay");

    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let removed = through(&transport, &outbox, &clock, &FULL)
        .remove_members(&admin.circle, &group, std::slice::from_ref(&target))
        .await
        .expect("the removal is asked for again");
    assert!(
        removed.status == haven_core::relay::fanout::EvolutionStatus::Confirmed
            && !roster(&admin, &group).await.contains(&target),
        "premise: the removal was made",
    );
    assert!(
        matches!(
            foreground_seal(&admin, &transport, &group).await,
            LocationSeal::Sealed { .. }
        ),
        "the removal, made, still held the circle's seals",
    );
}

/// The hold lasts only while a member it named is listed: once another
/// admin's commit has removed them, the claimed foreground's seal is made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_set_aside_stops_holding_once_its_member_is_no_longer_listed() {
    use haven_core::relay::fanout::{LocationSeal, SendHeld};

    let (admin, others, group) = a_removal_held().await;
    let target = others[0].pubkey_hex();
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    assert!(
        matches!(
            foreground_seal(&admin, &transport, &group).await,
            LocationSeal::Deferred(SendHeld::RemovalUnmade)
        ),
        "premise: the hold stands",
    );
    let heir = &others[1];
    make_admins(&admin, &[&others[0], heir], &group, &[&admin, heir]).await;
    let removal = confirmed(
        heir,
        &heir
            .session()
            .remove_members(&group, std::slice::from_ref(&target))
            .await
            .expect("the other admin removes the member"),
    )
    .await;
    admin
        .session()
        .process_event_settled_for_test(&removal)
        .await
        .expect("the removal is applied");
    assert!(
        !roster(&admin, &group).await.contains(&target),
        "premise: the member is gone"
    );
    assert!(
        matches!(
            foreground_seal(&admin, &transport, &group).await,
            LocationSeal::Sealed { .. }
        ),
        "a removal whose member is no longer listed still held the circle's seals",
    );
    assert!(held(&admin).is_empty(), "the member stayed kept");
}
