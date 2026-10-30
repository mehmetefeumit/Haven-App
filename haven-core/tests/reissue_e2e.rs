//! A change of this device's that branch selection withdrew is handed back to
//! MDK — its own re-issue entries, never a second implementation — and what
//! became of it is returned typed. The roster never shows a withdrawn change
//! as applied, a change still valid is made again under a record, and one
//! that cannot be is said durably.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted and the
//! engine's own deadlines are served, never a count of advances.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::nostr::mls::types::{
    GroupId, MessageState, SessionEffects, WithdrawnKind, WithdrawnOutcome,
};
use haven_core::nostr::mls::{ChangeNote, SessionManager};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::DriveMode;
use helpers::drive::{roster, through, ManualClock, Recorder};
use helpers::removals::{confirmed, held};
use helpers::stranded::{co_admin, split, staged};
use helpers::{setup_circle, CircleMember};

const ONE: &str = "wss://one.reissue-canary3b9e.example.com";
const TWO: &str = "wss://two.reissue-canary3b9e.example.com";
const THREE: &str = "wss://three.reissue-canary3b9e.example.com";
const FULL: DriveMode = DriveMode::Full;

/// Serves the deadlines the engine announces for `group` until it owes
/// nothing soon.
async fn settled(member: &CircleMember, group: &GroupId) {
    let session = member.session();
    let _ = session.advance_for_receive(group).await;
    while let Some(after) = session.receive_retick_after(group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(group).await;
    }
}

/// `a` and `b` each confirm a commit they made at the same epoch — `by_a`,
/// `by_b` — and each hears the other's: branch selection keeps one.
async fn cross(
    a: &CircleMember,
    b: &CircleMember,
    group: &GroupId,
    by_a: &SessionEffects,
    by_b: &SessionEffects,
) {
    let ((event_a, pending_a), (event_b, pending_b)) = (staged(by_a), staged(by_b));
    a.session()
        .confirm_published(pending_a)
        .await
        .expect("a's relays took it");
    b.session()
        .confirm_published(pending_b)
        .await
        .expect("b's relays took it");
    let _ = a.session().process_event_settled_for_test(&event_b).await;
    let _ = b.session().process_event_settled_for_test(&event_a).await;
    settled(a, group).await;
    settled(b, group).await;
}

/// Of `a` and `b`, whose changes named `of_a` and `of_b`, the one whose
/// change branch selection withdrew, the other, and what the withdrawn one
/// named. A withdrawn removal's member is still listed; a withdrawn
/// invite's is not.
async fn withdrawn_first(
    (a, b): (CircleMember, CircleMember),
    group: &GroupId,
    (of_a, of_b): (String, String),
    listed_if_withdrawn: bool,
) -> (CircleMember, CircleMember, String) {
    let listed = roster(&a, group).await;
    let a_lost = listed.contains(&of_a) == listed_if_withdrawn;
    let b_lost = listed.contains(&of_b) == listed_if_withdrawn;
    assert!(
        a_lost != b_lost && roster(&b, group).await == listed,
        "premise: branch selection kept exactly one change, the same on both",
    );
    if a_lost {
        (a, b, of_a)
    } else {
        (b, a, of_b)
    }
}

/// Two admins each remove a different member at the same epoch and each
/// hears the other's commit: branch selection keeps one removal. Returns
/// the admin whose removal was withdrawn, the other, the circle, and the
/// member the withdrawn removal named.
async fn two_removals_race() -> (CircleMember, CircleMember, GroupId, String) {
    let fx = setup_circle(4, &[ONE]).await;
    co_admin(&fx).await;
    let (a, mut others, group) = split(fx);
    let b = others.remove(0);
    let (m, n) = (others.remove(0).pubkey_hex(), others.remove(0).pubkey_hex());
    let by_a = a
        .session()
        .remove_members(&group, std::slice::from_ref(&m))
        .await
        .expect("a removes m");
    let by_b = b
        .session()
        .remove_members(&group, std::slice::from_ref(&n))
        .await
        .expect("b removes n");
    cross(&a, &b, &group, &by_a, &by_b).await;
    let (loser, winner, named) = withdrawn_first((a, b), &group, (m, n), true).await;
    (loser, winner, group, named)
}

/// One admin changes the circle's relays to [`THREE`] while the other
/// removes a member at the same epoch, and each hears the other's commit.
/// Both commits are privileged, so branch selection keeps the one whose
/// committer sorts lower (MDK `convergence.rs` 138-146): the relay change is
/// given to the other admin, and is withdrawn. Returns that admin, the other,
/// the circle, and the relays the withdrawn change asked for. What MDK's
/// re-issue does with a withdrawn change is shown on this one, which is still
/// valid against the kept branch: a withdrawn removal is never handed to it
/// (decision 233).
async fn a_withdrawn_relay_change() -> (CircleMember, CircleMember, GroupId, Vec<String>) {
    let (loser, winner, group, wanted, _commit) = a_withdrawn_relay_change_and_its_commit().await;
    (loser, winner, group, wanted)
}

/// [`a_withdrawn_relay_change`], with the id of the withdrawn commit.
async fn a_withdrawn_relay_change_and_its_commit() -> (
    CircleMember,
    CircleMember,
    GroupId,
    Vec<String>,
    nostr::EventId,
) {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (a, mut others, group) = split(fx);
    let b = others.remove(0);
    let gone = others.remove(0).pubkey_hex();
    let (loser, winner) = if a.keys.public_key().to_bytes() > b.keys.public_key().to_bytes() {
        (a, b)
    } else {
        (b, a)
    };
    let wanted = vec![THREE.to_string()];
    let by_loser = loser
        .session()
        .update_relays(&group, wanted.clone())
        .await
        .expect("one admin changes the relays");
    let by_winner = winner
        .session()
        .remove_members(&group, std::slice::from_ref(&gone))
        .await
        .expect("the other removes a member");
    cross(&loser, &winner, &group, &by_loser, &by_winner).await;
    assert!(
        parked(&loser, &by_loser).await
            && !parked(&winner, &by_winner).await
            && relays_of(&loser, &group).await != wanted
            && !roster(&loser, &group).await.contains(&gone),
        "premise: branch selection kept the removal and withdrew the relay change",
    );
    let commit = staged(&by_loser).0.id;
    (loser, winner, group, wanted, commit)
}

/// Whether `member`'s own commit in `effects` is stored as set aside by
/// branch selection.
async fn parked(member: &CircleMember, effects: &SessionEffects) -> bool {
    let id = staged(effects).0.id;
    matches!(
        member
            .session()
            .stored_message_record_for_test(&haven_core::nostr::mls::types::MessageId::new(
                id.to_bytes().to_vec()
            ))
            .await
            .expect("the store is read")
            .map(|record| record.state),
        Some(MessageState::ConvergenceDeferred | MessageState::EpochInvalidated)
    )
}

/// The relays `member`'s row says `group` is on.
async fn relays_of(member: &CircleMember, group: &GroupId) -> Vec<String> {
    member
        .circle
        .get_circle(group)
        .await
        .expect("read the circle")
        .expect("the circle exists")
        .circle
        .relays
}

/// `by`'s invite of `newcomer` to `group`, staged the legacy way.
async fn invite(by: &CircleMember, group: &GroupId, newcomer: &CircleMember) -> SessionEffects {
    invite_spending(by, group, newcomer).await.0
}

/// [`invite`], with the `KeyPackage` event the invite spends.
async fn invite_spending(
    by: &CircleMember,
    group: &GroupId,
    newcomer: &CircleMember,
) -> (SessionEffects, nostr::Event) {
    let event =
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[ONE.to_string()])
            .await;
    let effects = by
        .session()
        .add_members(
            group,
            vec![SessionManager::key_package_from_event(&event).expect("it parses")],
        )
        .await
        .expect("the newcomer is invited");
    (effects, event)
}

/// As [`two_removals_race`], each admin inviting a different newcomer: the
/// withdrawn change is an invite, whose newcomer is not listed.
async fn two_invites_race() -> (CircleMember, CircleMember, GroupId, String) {
    let (loser, winner, group, newcomer) = two_invites_race_keeping_the_newcomer().await;
    (loser, winner, group, newcomer.pubkey_hex())
}

/// [`two_invites_race`], with the newcomer the withdrawn invite named.
async fn two_invites_race_keeping_the_newcomer(
) -> (CircleMember, CircleMember, GroupId, CircleMember) {
    let (loser, winner, group, newcomer, _spent) = two_invites_race_spending().await;
    (loser, winner, group, newcomer)
}

/// [`two_invites_race_keeping_the_newcomer`], with the `KeyPackage` event the
/// withdrawn invite spent.
async fn two_invites_race_spending() -> (
    CircleMember,
    CircleMember,
    GroupId,
    CircleMember,
    nostr::Event,
) {
    let fx = setup_circle(2, &[ONE]).await;
    co_admin(&fx).await;
    let (a, mut others, group) = split(fx);
    let b = others.remove(0);
    let (x, y) = (CircleMember::new(), CircleMember::new());
    let (by_a, of_x) = invite_spending(&a, &group, &x).await;
    let (by_b, of_y) = invite_spending(&b, &group, &y).await;
    cross(&a, &b, &group, &by_a, &by_b).await;
    let (loser, winner, named) =
        withdrawn_first((a, b), &group, (x.pubkey_hex(), y.pubkey_hex()), false).await;
    if named == x.pubkey_hex() {
        (loser, winner, group, x, of_x)
    } else {
        (loser, winner, group, y, of_y)
    }
}

/// A change other than a removal that branch selection withdrew — here the
/// circle's relays — is still re-issued by MDK at the next full drive, made
/// under a record, and applied (decision 233 drops only removals).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_relay_change_is_still_reissued_through_mdk_and_made() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.kind == WithdrawnKind::AppComponents
                && change.outcome == WithdrawnOutcome::Reissued)
            && relays_of(&loser, &group).await == wanted
            && !transport.calls().is_empty(),
        "a withdrawn relay change was not made again through MDK",
    );
}

/// A change withdrawn from a circle whose routing id is another circle's on
/// this device too is not made again — a full drive makes no commit of it
/// and asks no relay — and stays owed after the leave is proposed: in the
/// circle MDK stopped routing to, it would be made at an epoch the circle
/// may have left. The leave is made, and ends at its bound.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_in_a_collided_circle_is_not_made_and_stays_owed_past_the_leave() {
    use haven_core::relay::fanout::{LeaveStatus, LEAVE_BOUND_MS};
    let (loser, _winner, group, wanted, commit) = a_withdrawn_relay_change_and_its_commit().await;
    loser.session().mark_caught_up_for_test(&group);
    loser
        .session()
        .note_routing_collision_for_test(&group)
        .expect("the hold is noted");
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted, Answer::Accepted, Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let resumed = driver.resume(&loser.circle).await;
    assert!(
        resumed.withdrawn.is_empty()
            && transport.calls().is_empty()
            && relays_of(&loser, &group).await != wanted
            && loser.session().own_commit_intent_retained_for_test(&commit),
        "a change withdrawn from a circle whose routing id is shared was made again, or let go",
    );

    let pubkey = loser.keys.public_key();
    let left = driver
        .leave(&loser.circle, &group, &pubkey)
        .await
        .expect("the leave is answered");
    let resumed = driver.resume(&loser.circle).await;
    assert!(
        left.status == LeaveStatus::Proposed
            && transport.calls().iter().all(|call| call.target == ONE)
            && resumed.withdrawn.is_empty()
            && relays_of(&loser, &group).await != wanted
            && loser.session().own_commit_intent_retained_for_test(&commit),
        "the leave of a held circle was not proposed, or the change withdrawn there was made \
         again or let go once it was ({:?})",
        left.status,
    );
    clock.set(LEAVE_BOUND_MS + 1_000);
    let ended = driver
        .resume_leave(&loser.circle, &group, &pubkey)
        .await
        .expect("the leave carries on");
    assert!(
        ended.status == LeaveStatus::Completed
            && loser
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_none(),
        "the leave of a held circle did not end at its bound",
    );
}

/// The user's own FRESH removal of a member — nothing set it aside, so no
/// member is kept — loses to a co-admin's removal of that member and their
/// invitation back. MDK's re-issue would remove them again: its record names
/// a member id it cannot tell from the one invited back (T-REISSUE ask 4).
/// So it is never handed to MDK (decision 233): it is dropped as an offer,
/// the member stays and is held, the circle is told both that a removal was
/// dropped and that a change was withdrawn, and nothing is staged.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fresh_own_removal_that_loses_to_a_removal_and_an_invite_back_is_dropped_and_held() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let (co, member) = (others.remove(0), others.remove(0));
    let named = member.pubkey_hex();
    confirmed(
        &admin,
        &admin
            .session()
            .remove_members(&group, std::slice::from_ref(&named))
            .await
            .expect("the user removes the member"),
    )
    .await;
    assert!(
        held(&admin).is_empty(),
        "premise: a fresh removal keeps no member"
    );
    let removal = confirmed(
        &co,
        &co.session()
            .remove_members(&group, std::slice::from_ref(&named))
            .await
            .expect("the co-admin removes the member"),
    )
    .await;
    let invite_back = confirmed(&co, &invite(&co, &group, &member).await).await;
    for event in [&removal, &invite_back] {
        let _ = admin.session().process_event(event).await;
    }
    settled(&admin, &group).await;
    assert!(
        roster(&admin, &group).await.contains(&named)
            && roster(&admin, &group).await == roster(&co, &group).await,
        "premise: this device adopted the co-admin's branch, with the member back",
    );
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    let notes = admin.session().peek_change_notes(&group);
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.kind == WithdrawnKind::RemoveMembers
                && change.outcome == WithdrawnOutcome::Abandoned)
            && transport.calls().is_empty()
            && roster(&admin, &group).await.contains(&named),
        "a fresh removal that lost to a removal and an invite back was made again",
    );
    assert!(
        held(&admin) == [named]
            && notes.contains(&ChangeNote::QueuedRemovalDropped)
            && notes.contains(&ChangeNote::ChangeWithdrawn),
        "the member a dropped removal named was not held, or the circle was not told",
    );
}

/// A withdrawn removal naming two members — one a removal set aside already
/// keeps, one named afresh — is dropped with BOTH held: a member the removal
/// named is never left reading the circle's background locations unheld.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_dropped_removal_holds_every_member_it_named() {
    let fx = setup_circle(5, &[ONE]).await;
    co_admin(&fx).await;
    let (a, mut others, group) = split(fx);
    let b = others.remove(0);
    let (fresh, kept, other) = (
        others.remove(0).pubkey_hex(),
        others.remove(0).pubkey_hex(),
        others.remove(0).pubkey_hex(),
    );
    // Both removals are privileged, so the one whose committer sorts lower
    // is kept (MDK `convergence.rs` 138-146): the two-member removal is
    // given to the other admin, and is withdrawn.
    let (loser, winner) = if a.keys.public_key().to_bytes() > b.keys.public_key().to_bytes() {
        (a, b)
    } else {
        (b, a)
    };
    let both = [fresh.clone(), kept.clone()];
    let by_loser = loser
        .session()
        .remove_members(&group, &both)
        .await
        .expect("one admin removes two members");
    let by_winner = winner
        .session()
        .remove_members(&group, std::slice::from_ref(&other))
        .await
        .expect("the other removes another");
    cross(&loser, &winner, &group, &by_loser, &by_winner).await;
    assert!(
        roster(&loser, &group).await.contains(&fresh)
            && !roster(&loser, &group).await.contains(&other),
        "premise: branch selection kept the other removal and withdrew the two-member one",
    );
    let by_loser = both.to_vec();
    // The loser's removal set aside of one member it named, kept as an open
    // keeps it.
    let kept_now = kept.clone();
    loser
        .session()
        .queue_removal_intent_for_test(&group, std::slice::from_ref(&kept_now))
        .await
        .expect("queued");
    let loser = loser.reopen();
    assert_eq!(held(&loser), [kept_now], "premise: one member is kept");
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    let mut named = by_loser;
    named.sort();
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.kind == WithdrawnKind::RemoveMembers
                && change.outcome == WithdrawnOutcome::Abandoned)
            && transport.calls().is_empty(),
        "premise: the withdrawn removal was dropped",
    );
    assert_eq!(
        held(&loser),
        named,
        "a member a dropped removal named was left unheld",
    );
}

/// A withdrawn removal whose drop could not be said — the circle's notes
/// cannot be written — stays where it is: MDK's record is not deleted,
/// nothing is re-issued and MDK's state-derived re-issue does not run. Once
/// the notes can be written, the next drive drops it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_removal_whose_drop_cannot_be_said_stays_in_place() {
    let (loser, _winner, group, target) = two_removals_race().await;
    loser.session().mark_caught_up_for_test(&group);
    let store = helpers::removals::store(&loser);
    store
        .execute_batch("ALTER TABLE commit_notes RENAME TO commit_notes_unwritable;")
        .expect("the notes cannot be written");
    let unsaid = loser.session().reissue_next_withdrawn_for_test().await;
    store
        .execute_batch("ALTER TABLE commit_notes_unwritable RENAME TO commit_notes;")
        .expect("the notes can be written again");
    assert!(
        unsaid.is_none()
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 0
            && roster(&loser, &group).await.contains(&target),
        "a withdrawn removal was dropped unsaid, or re-issued",
    );
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.kind == WithdrawnKind::RemoveMembers
                && change.outcome == WithdrawnOutcome::Abandoned)
            && transport.calls().is_empty()
            && roster(&loser, &group).await.contains(&target)
            && loser
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a withdrawn removal left in place was not dropped once its notes could be written",
    );
}

/// Until it is made again, a withdrawn change is not shown as applied: the
/// circle stands on the relays the kept change set.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_is_not_shown_as_applied() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    assert!(
        relays_of(&loser, &group).await != wanted,
        "a withdrawn change was shown as applied",
    );
    // Not caught up: nothing is asked of MDK, and nothing is made.
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed.withdrawn.is_empty()
            && transport.calls().is_empty()
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 0
            && relays_of(&loser, &group).await != wanted,
        "a withdrawn change was made again, or queued, before its circle was caught up",
    );
}

/// A withdrawn change MDK will not queue again — it lost more races than
/// MDK retries — is returned typed as abandoned, is not applied, and the
/// circle is told the user has to ask again. (MDK's other abandoning answer,
/// a full queue, is never reached: a circle with a change queued is not
/// asked about.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_abandoned_reissue_is_returned_typed_and_the_change_is_not_applied() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    // As MDK's record reads once its change lost more races than it retries
    // (`own_commit_intent.rs` 183-191): the field its own tests write.
    let loser = reopened_after(loser, |store| {
        use cgka_traits::storage::OutboundIntentStorage as _;
        for mut record in store
            .list_own_commit_intents(Some(&group))
            .expect("the intents are read")
        {
            record.reissue_attempts =
                cgka_engine::own_commit_intent::MAX_OWN_COMMIT_REISSUE_ATTEMPTS;
            store
                .put_own_commit_intent(&record)
                .expect("the intent is rewritten");
        }
    });
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.kind == WithdrawnKind::AppComponents
                && change.outcome == WithdrawnOutcome::Abandoned)
            && relays_of(&loser, &group).await != wanted
            && loser
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ChangeWithdrawn)
            && transport.calls().is_empty(),
        "an abandoned re-issue was not returned typed, or was applied, or the circle was not \
         told",
    );
}

/// A commit made at `group`'s current epoch by `member`, applied.
async fn self_update(member: &CircleMember, group: &GroupId) {
    let (_, pending) = staged(
        &member
            .session()
            .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
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

/// MDK keeps the intent of a confirmed own commit while a late rival could
/// still roll it back, and the state-derived pass a full drive makes
/// collects it once the circle is past the rewind horizon. One intent it
/// does NOT collect today is pinned too: that of a commit the engine's
/// hydrate cleared, staged with no record — the leg goes red the day MDK
/// collects it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn own_commit_intents_are_collected_past_the_rewind_horizon() {
    let fx = setup_circle(4, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let (kept, pending) = staged(
        &admin
            .session()
            .remove_members(&group, &[others[0].pubkey_hex()])
            .await
            .expect("a removal"),
    );
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("applied");
    // A change that removes nobody, interrupted before its confirm: the
    // engine's hydrate clears it at the next open, and records nothing.
    let (orphan, _never) = staged(
        &admin
            .session()
            .update_relays(&group, vec![TWO.to_string()])
            .await
            .expect("a relay change left staged"),
    );
    let admin = admin.reopen();
    assert!(
        helpers::drive::staged_ref(&admin, &group).await.is_none(),
        "premise: the open cleared the interrupted change",
    );
    assert!(
        admin
            .session()
            .own_commit_intent_retained_for_test(&kept.id)
            && admin
                .session()
                .own_commit_intent_retained_for_test(&orphan.id),
        "premise: both intents are retained",
    );
    for _ in 0..=haven_core::nostr::mls::max_rewind_commits() {
        self_update(&admin, &group).await;
    }
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    assert!(
        !admin
            .session()
            .own_commit_intent_retained_for_test(&kept.id),
        "the intent of a commit past the rewind horizon was not collected",
    );
    // The pin below names one cause only while the orphan's row is neither
    // applied (which MDK collects past the horizon) nor parked (which it
    // re-issues).
    let orphaned = admin
        .session()
        .stored_message_record_for_test(&haven_core::nostr::mls::types::MessageId::new(
            orphan.id.to_bytes().to_vec(),
        ))
        .await
        .expect("the store is read")
        .map(|record| record.state);
    assert!(
        !matches!(
            orphaned,
            Some(
                MessageState::Processed
                    | MessageState::ConvergenceDeferred
                    | MessageState::EpochInvalidated
            )
        ),
        "premise: the orphan's row is neither applied nor parked",
    );
    assert!(
        admin
            .session()
            .own_commit_intent_retained_for_test(&orphan.id),
        "MDK now collects the intent of a commit its hydrate cleared: this pin, and the \
         tracker's T-REISSUE row, are to be updated",
    );
}

/// A withdrawn change in a circle this device is leaving is not made again —
/// MDK sends nothing of such a circle but the leave — and not counted as
/// failed: it is retired, typed, and only the copy MDK queued again is taken
/// back; another change the user queued stands. While whether the circle is
/// being left cannot be read, nothing is asked of MDK and nothing is taken.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_in_a_circle_being_left_is_retired_not_failed() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    let admins = loser
        .session()
        .admin_pubkeys(&group)
        .await
        .expect("the admins");
    loser
        .session()
        .queue_admin_policy_intent_for_test(
            &group,
            SessionManager::admin_policy_payload_for_test(&admins).expect("payload"),
        )
        .await
        .expect("another change is queued");
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = rusqlite::Connection::open(
        loser
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens");
    store
        .execute(
            "INSERT INTO user_settings (key, value) VALUES (?1, '1700000000')",
            [format!("leave_intent_v1:{}", hex::encode(group.as_slice()))],
        )
        .expect("the leave intent is written");
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let queued = || async {
        loser
            .session()
            .queued_intent_count_for_test(&group)
            .await
            .expect("read")
    };

    store
        .execute_batch("ALTER TABLE user_settings RENAME TO user_settings_unread;")
        .expect("the leave intent cannot be read");
    let unread = driver.resume(&loser.circle).await;
    store
        .execute_batch("ALTER TABLE user_settings_unread RENAME TO user_settings;")
        .expect("the leave intent reads again");
    assert!(
        unread.withdrawn.is_empty()
            && queued().await == 1
            && relays_of(&loser, &group).await != wanted,
        "a withdrawn change was decided on, or a queued change taken, while whether its \
         circle was being left could not be read",
    );

    let resumed = driver.resume(&loser.circle).await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.kind == WithdrawnKind::AppComponents
                && change.outcome == WithdrawnOutcome::RetiredForLeave)
            && queued().await == 1
            && !loser
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ChangeWithdrawn)
            && relays_of(&loser, &group).await != wanted,
        "a withdrawn change in a circle being left was made or left queued, another queued \
         change was taken with it, or it was counted failed",
    );
}

/// A withdrawn change MDK could not be asked about — the engine held behind
/// a rollback not yet retired, or MDK's own write failing — stays owed in
/// MDK's store: the next drive that can ask does, and the change is made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_stays_owed_while_the_engine_is_held_or_mdk_errs() {
    use haven_core::nostr::mls::storage::{
        set_commit_retirement_fault_for_test, set_engine_write_fault_for_test, EngineWrite,
    };
    use haven_core::nostr::mls::types::FanoutId;
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    let (db, key) = helpers::stranded::mls_db(loser.dir.path());
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Refused]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);

    // A relay change every relay refuses, whose rolled-back commit cannot be
    // retired: the engine is held until it is.
    let staged = loser
        .session()
        .update_relays_staging(&group, vec![TWO.to_string()], 0)
        .await
        .expect("a relay change is staged");
    let [id] =
        <[FanoutId; 1]>::try_from(staged.fanouts).unwrap_or_else(|_| panic!("premise: one record"));
    let commit = loser
        .session()
        .fanout_probe_for_test(&id)
        .await
        .expect("read")
        .expect("the record")
        .event_id;
    set_commit_retirement_fault_for_test(&db, &key, commit.as_bytes(), true).expect("arm");
    let _ = driver.resume(&loser.circle).await;
    loser.session().mark_caught_up_for_test(&group);
    let held = driver.resume(&loser.circle).await;
    set_commit_retirement_fault_for_test(&db, &key, commit.as_bytes(), false).expect("disarm");
    assert!(
        held.withdrawn.is_empty() && relays_of(&loser, &group).await != wanted,
        "a withdrawn change was asked about while the engine was held",
    );

    set_engine_write_fault_for_test(&db, &key, EngineWrite::OwnCommitIntentDelete, true)
        .expect("arm");
    let erred = driver.resume(&loser.circle).await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::OwnCommitIntentDelete, false)
        .expect("disarm");
    assert!(
        erred.withdrawn.is_empty() && relays_of(&loser, &group).await != wanted,
        "a withdrawn change MDK failed to decide on was reported, or made",
    );

    transport.answer(ONE, [Answer::Accepted]);
    let made = driver.resume(&loser.circle).await;
    assert!(
        made.withdrawn
            .iter()
            .any(|change| change.group_id == group && change.outcome == WithdrawnOutcome::Reissued)
            && relays_of(&loser, &group).await == wanted,
        "a withdrawn change MDK could not be asked about was not asked about again, or not made",
    );
}

/// A withdrawn change of a device since removed from the circle is said to
/// be no member's: nothing is made, and the user is not told to ask again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_of_a_device_since_removed_is_no_members() {
    let (loser, winner, group, _target) = two_removals_race().await;
    let (eviction, pending) = staged(
        &winner
            .session()
            .remove_members(&group, &[loser.pubkey_hex()])
            .await
            .expect("the other admin removes this one"),
    );
    winner
        .session()
        .confirm_published(pending)
        .await
        .expect("applied");
    let _ = loser
        .session()
        .process_event_settled_for_test(&eviction)
        .await;
    assert!(
        loser.session().removed_for_test(&group).await,
        "premise: this device is removed",
    );
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group && change.outcome == WithdrawnOutcome::NotMember)
            && !loser
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ChangeWithdrawn) && transport.calls().is_empty(),
        "a removed device's withdrawn change was not said to be no member's, or was made, or \
         the user was told to ask again",
    );
}

/// A withdrawn invite is not made again — its `KeyPackage` went to a Welcome
/// that will never be valid — and the circle is told the newcomer has to be
/// invited again with a fresh one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_invite_is_said_to_need_a_fresh_invite() {
    let (loser, _winner, group, newcomer) = two_invites_race().await;
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.kind == WithdrawnKind::Invite
                && change.outcome == WithdrawnOutcome::ReinviteRequired)
            && loser
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ReinviteOwed)
            && !roster(&loser, &group).await.contains(&newcomer),
        "a withdrawn invite was made again, or the circle was not told to invite afresh",
    );
}

/// A withdrawal is read from what the store keeps, not from the process
/// that heard of it: a session that never drove it ends, and the next one
/// makes the change again — with a circle this device was removed from, and
/// so can never catch up with, present beside it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawal_a_session_never_drove_is_made_again_by_the_next() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    let host = CircleMember::new();
    let elsewhere = helpers::found_circle(&host, &[&loser], &[ONE]).await;
    let (eviction, pending) = staged(
        &host
            .session()
            .remove_members(&elsewhere, &[loser.pubkey_hex()])
            .await
            .expect("the other circle's admin removes this device"),
    );
    host.session()
        .confirm_published(pending)
        .await
        .expect("applied");
    let _ = loser
        .session()
        .process_event_settled_for_test(&eviction)
        .await;
    assert!(
        loser.session().removed_for_test(&elsewhere).await,
        "premise: this device was removed from the other circle",
    );
    let loser = loser.reopen();
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group && change.outcome == WithdrawnOutcome::Reissued)
            && relays_of(&loser, &group).await == wanted,
        "a withdrawal heard by an earlier session was not made again",
    );
}

/// A change MDK queued again that the drive's advance did not stage is
/// returned as queued, not as re-issued, and stays queued for the circle's
/// next full advance; set aside at an open instead, nothing asks for it
/// again on top of MDK's own attempts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_queued_again_and_not_staged_is_returned_queued() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    loser.session().mark_caught_up_for_test(&group);
    loser.session().fail_next_full_advance_for_test();
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.kind == WithdrawnKind::AppComponents
                && change.outcome == WithdrawnOutcome::Queued)
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 1
            && relays_of(&loser, &group).await != wanted,
        "a withdrawn change MDK queued and the drive did not stage was reported re-issued, or \
         lost",
    );

    // Set aside at the next open, the copy MDK re-issued is a change the
    // circle is told was dropped, and one nothing asks for again: MDK has had
    // its own attempts at it.
    let _ = transport.calls();
    let loser = loser.reopen();
    loser.session().mark_caught_up_for_test(&group);
    assert!(
        loser
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedChangeDropped),
        "premise: the open set the re-issued copy aside, and said so",
    );
    let after = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        after.withdrawn.is_empty()
            && transport.calls().is_empty()
            && relays_of(&loser, &group).await != wanted,
        "a set-aside copy MDK had re-issued was made again",
    );
}

/// Ends `member`'s process, lets `edit` change its closed MLS store, and
/// starts another over it.
fn reopened_after(
    member: CircleMember,
    edit: impl FnOnce(&storage_sqlite::SqliteAccountStorage),
) -> CircleMember {
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    let (db, key) = helpers::stranded::mls_db(dir.path());
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = storage_sqlite::SqliteAccountStorage::open_encrypted_with_options(
        &db,
        &key,
        haven_core::nostr::mls::StorageConfig::storage_options(),
    )
    .expect("the closed store opens");
    edit(&store);
    drop(store);
    CircleMember {
        circle: std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
                .expect("the stores reopen"),
        ),
        keys,
        dir,
    }
}

/// With a change of the group queued in its circle, a withdrawn change is not
/// handed to MDK: what MDK queued again would wait behind it. Once the queue
/// is clear, it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_waits_while_its_circle_has_a_change_queued() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    let admins = loser
        .session()
        .admin_pubkeys(&group)
        .await
        .expect("the admins");
    loser
        .session()
        .queue_admin_policy_intent_for_test(
            &group,
            SessionManager::admin_policy_payload_for_test(&admins).expect("payload"),
        )
        .await
        .expect("a change is queued");
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let held = driver.resume(&loser.circle).await;
    assert!(
        held.withdrawn.is_empty() && relays_of(&loser, &group).await != wanted,
        "a withdrawn change was handed to MDK behind a change queued in its circle",
    );
    loser
        .session()
        .take_back_queued_changes_for_test(&group)
        .await;
    let resumed = driver.resume(&loser.circle).await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.outcome == WithdrawnOutcome::Reissued)
            && relays_of(&loser, &group).await == wanted,
        "a withdrawn change was not made again once its circle's queue was clear",
    );
}

/// Deletes `group`'s row from `member`'s circle store: the circle was left,
/// and its MLS state is kept until it is forgotten.
fn without_its_row(member: &CircleMember, group: &GroupId) {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        member
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .execute_batch(&format!(
        "PRAGMA foreign_keys = OFF; DELETE FROM circles WHERE mls_group_id = x'{}';",
        hex::encode(group.as_slice())
    ))
    .expect("the circle's row is gone");
}

/// A circle this device keeps no row for gets nothing made again: the copy
/// MDK queued again of a withdrawn change is taken back, and the change is
/// retired, not failed. A withdrawn removal there has nobody to hold for and
/// nobody to tell: MDK's record goes alone, said to be no member's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_in_a_circle_with_no_row_is_retired() {
    let (loser, _winner, group, _wanted) = a_withdrawn_relay_change().await;
    without_its_row(&loser, &group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.outcome == WithdrawnOutcome::RetiredForLeave)
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 0
            && transport.calls().is_empty(),
        "a withdrawn change in a circle with no row was made again, or left queued",
    );

    let (loser, _winner, group, target) = two_removals_race().await;
    without_its_row(&loser, &group);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.kind == WithdrawnKind::RemoveMembers
                && change.outcome == WithdrawnOutcome::NotMember)
            && held(&loser).is_empty()
            && loser.session().peek_change_notes(&group).is_empty()
            && transport.calls().is_empty()
            && roster(&loser, &group).await.contains(&target),
        "a withdrawn removal in a circle with no row was made, or held and told for a circle \
         that is gone",
    );
}

/// A circle with no row that is not yet stable — a commit of this device's
/// staged — is not asked about, and holds back MDK's state-derived call,
/// which would re-issue every parked record it finds behind Haven's back: the
/// withdrawn change stays owed, and nothing is queued again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_in_an_unsettled_circle_with_no_row_holds_back_mdks_reissue() {
    let (loser, _winner, group, _wanted) = a_withdrawn_relay_change().await;
    let _unconfirmed = loser
        .session()
        .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
            group_id: group.clone(),
        })
        .await
        .expect("a self-update is staged");
    without_its_row(&loser, &group);
    loser.session().mark_caught_up_for_test(&group);
    let asked = loser.session().reissue_next_withdrawn_for_test().await;
    assert!(
        asked.is_none()
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 0,
        "a withdrawn change of an unsettled circle with no row was re-issued by MDK's \
         state-derived call",
    );
}

/// A leave MDK holds with no intent of Haven's — the legacy path asks for one
/// so — counts as leaving: a withdrawn change there is retired, its queued
/// copy taken back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_in_a_circle_mdk_holds_a_leave_for_is_retired() {
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    let loser = reopened_after(loser, |store| {
        use cgka_traits::storage::LeaveRequestStorage as _;
        store
            .put_leave_request(&cgka_traits::storage::LeaveRequest {
                group_id: group.clone(),
                requested_at_ms: 0,
                last_proposed_epoch: None,
            })
            .expect("MDK holds a leave");
    });
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.outcome == WithdrawnOutcome::RetiredForLeave)
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 0
            && relays_of(&loser, &group).await != wanted,
        "a withdrawn change in a circle MDK holds a leave for was not retired",
    );
}

/// In a circle being left, a re-issued copy that cannot be taken back is
/// returned queued — still in the engine's queue — never as retired.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reissued_copy_that_cannot_be_taken_back_is_returned_queued() {
    use haven_core::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
    let (loser, _winner, group, _wanted) = a_withdrawn_relay_change().await;
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        loser
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .execute(
        "INSERT INTO user_settings (key, value) VALUES (?1, '1700000000')",
        [format!("leave_intent_v1:{}", hex::encode(group.as_slice()))],
    )
    .expect("the leave intent is written");
    loser.session().mark_caught_up_for_test(&group);
    let (db, key) = helpers::stranded::mls_db(loser.dir.path());
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true).expect("arm");
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
        .expect("disarm");
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.outcome == WithdrawnOutcome::Queued)
            && loser
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("read")
                == 1,
        "a re-issued copy that could not be taken back was said to be retired, or is gone",
    );
}

/// A store that cannot read a withdrawn change's commit or its circle asks
/// MDK nothing: the change stays owed, and is made once the store reads
/// again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_change_the_store_cannot_read_stays_owed() {
    use haven_core::nostr::mls::storage::{
        set_group_read_fault_for_test, set_message_read_fault_for_test,
    };
    let (loser, _winner, group, wanted) = a_withdrawn_relay_change().await;
    loser.session().mark_caught_up_for_test(&group);
    let (db, key) = helpers::stranded::mls_db(loser.dir.path());
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    for fault in [
        set_message_read_fault_for_test,
        set_group_read_fault_for_test,
    ] {
        fault(&db, &key, true).expect("arm");
        let unread = loser.session().reissue_next_withdrawn_for_test().await;
        fault(&db, &key, false).expect("disarm");
        assert!(
            unread.is_none() && relays_of(&loser, &group).await != wanted,
            "a withdrawn change was decided on though the store could not read it",
        );
    }
    let resumed = driver.resume(&loser.circle).await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.outcome == WithdrawnOutcome::Reissued)
            && relays_of(&loser, &group).await == wanted,
        "a withdrawn change the store could not read was not made once it could",
    );
}

/// What a re-invite's lookup finds: a fresh package of the newcomer, with
/// their inbox, or nothing; and how often it was asked.
struct Lookup {
    found: Option<haven_core::circle::MemberKeyPackage>,
    asked: std::sync::atomic::AtomicUsize,
}

impl haven_core::relay::fanout::ReinviteLookup for Lookup {
    fn member<'a>(
        &'a self,
        _circle: &'a haven_core::circle::CircleManager,
        _group_id: &'a GroupId,
        _invitee: &'a str,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = Option<haven_core::circle::MemberKeyPackage>>
                + Send
                + 'a,
        >,
    > {
        self.asked.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Box::pin(async move { self.found.clone() })
    }
}

const INBOX: &str = "wss://inbox.reissue-canary3b9e.example.com";

/// An invite branch selection withdrew whose package is spent is made again
/// with a fresh one: MDK reserves a lookup, the newcomer's fresh package is
/// found, MDK queues the invite and the same call stages it under a record;
/// once a relay takes the commit the newcomer is in the circle and their
/// Welcome goes to their inbox relays and nowhere else. Nothing is owed
/// after.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_mdk_owes_is_made_with_a_fresh_package_and_its_welcome_reaches_the_inbox() {
    use haven_core::relay::fanout::ReinviteResult;

    let (loser, _winner, group, newcomer) = two_invites_race_keeping_the_newcomer().await;
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let resumed = driver.resume(&loser.circle).await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.outcome == WithdrawnOutcome::ReinviteRequired),
        "premise: MDK owes a re-invite",
    );
    let lookup = Lookup {
        found: Some(haven_core::circle::MemberKeyPackage {
            key_package_event: helpers::create_key_package_event(
                newcomer.session(),
                &newcomer.keys,
                &[INBOX.to_string()],
            )
            .await,
            inbox_relays: vec![INBOX.to_string()],
            nip65_relays: Vec::new(),
        }),
        asked: std::sync::atomic::AtomicUsize::new(0),
    };

    let reinvited = driver.reinvite(&loser.circle, &lookup).await;
    assert!(
        reinvited.len() == 1
            && reinvited[0].group_id == group
            && reinvited[0].result == ReinviteResult::Reissued,
        "an owed re-invite was not made again under a record",
    );
    clock.set(60_000);
    let _ = driver.resume(&loser.circle).await;
    assert!(roster(&loser, &group)
        .await
        .contains(&newcomer.pubkey_hex()));
    let welcomes: Vec<_> = outbox
        .handed()
        .into_iter()
        .filter(|(event, _)| event.kind.as_u16() == 1059)
        .collect();
    assert!(
        welcomes.len() == 1
            && welcomes[0].1 == [INBOX]
            && welcomes[0]
                .0
                .tags
                .public_keys()
                .any(|p| p.to_hex() == newcomer.pubkey_hex()),
        "the re-invite's Welcome did not go to the newcomer's inbox, or went elsewhere",
    );
    assert!(driver.reinvite(&loser.circle, &lookup).await.is_empty());
    assert_eq!(lookup.asked.load(std::sync::atomic::Ordering::SeqCst), 1);
}

/// A re-invite whose newcomer has no package to find is looked for again
/// only on MDK's own schedule — 5 s, 30 s, 2 min, 10 min, 1 h, 6 h, a day, a
/// day — and given up after eight lookups: the circle keeps its note that
/// the newcomer has to be invited again, and nothing is looked up after.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_with_no_package_to_find_is_looked_for_on_mdks_schedule_and_then_given_up() {
    use haven_core::relay::fanout::ReinviteResult;

    let (loser, _winner, group, _newcomer) = two_invites_race_keeping_the_newcomer().await;
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _ = driver.resume(&loser.circle).await;
    transport.calls();
    let lookup = Lookup {
        found: None,
        asked: std::sync::atomic::AtomicUsize::new(0),
    };
    let result = |reinvited: Vec<haven_core::relay::fanout::Reinvite>| {
        let [one] = <[_; 1]>::try_from(reinvited)
            .unwrap_or_else(|_| panic!("the one owed re-invite is taken up"));
        one.result
    };

    let mut at = 0_u64;
    for wait in [
        5_000, 30_000, 120_000, 600_000, 3_600_000, 21_600_000, 86_400_000, 86_400_000,
    ] {
        assert_eq!(
            result(driver.reinvite(&loser.circle, &lookup).await),
            ReinviteResult::KeyPackageMissing
        );
        clock.set(at + wait - 1);
        assert_eq!(
            result(driver.reinvite(&loser.circle, &lookup).await),
            ReinviteResult::NotDue,
            "a lookup was made before MDK's wait was over",
        );
        at += wait;
        clock.set(at);
    }
    assert_eq!(
        result(driver.reinvite(&loser.circle, &lookup).await),
        ReinviteResult::GaveUp
    );
    assert!(driver.reinvite(&loser.circle, &lookup).await.is_empty());
    assert_eq!(lookup.asked.load(std::sync::atomic::Ordering::SeqCst), 8);
    assert!(loser
        .session()
        .peek_change_notes(&group)
        .contains(&ChangeNote::ReinviteOwed));
    assert!(
        transport.calls().is_empty(),
        "something was sent for a re-invite never made"
    );
}

/// A loser of an invite race whose re-invite MDK owes, with a full drive
/// made so MDK has said so: the loser, the circle, the newcomer, the package
/// the withdrawn invite spent, and a driver over a transport that accepts.
async fn an_owed_reinvite() -> (
    CircleMember,
    CircleMember,
    GroupId,
    CircleMember,
    nostr::Event,
) {
    let (loser, winner, group, newcomer, spent) = two_invites_race_spending().await;
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let resumed = through(&transport, &outbox, &clock, &FULL)
        .resume(&loser.circle)
        .await;
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.outcome == WithdrawnOutcome::ReinviteRequired),
        "premise: MDK owes a re-invite",
    );
    (loser, winner, group, newcomer, spent)
}

/// What a lookup finds of `newcomer`: the `KeyPackage` event `package`.
fn finding(package: nostr::Event) -> Lookup {
    Lookup {
        found: Some(haven_core::circle::MemberKeyPackage {
            key_package_event: package,
            inbox_relays: vec![INBOX.to_string()],
            nip65_relays: Vec::new(),
        }),
        asked: std::sync::atomic::AtomicUsize::new(0),
    }
}

/// The one re-invite a call took up.
fn only(
    reinvited: Vec<haven_core::relay::fanout::Reinvite>,
) -> haven_core::relay::fanout::ReinviteResult {
    let [one] = <[_; 1]>::try_from(reinvited)
        .unwrap_or_else(|_| panic!("the one owed re-invite is taken up"));
    one.result
}

/// The package a lookup finds is the one the withdrawn invite spent — an
/// invitee keeps it published while the invitation is unanswered (Security
/// Rule 5) — and MDK refuses it: the package is missing, never "ended", and
/// MDK still owes the re-invite, which a fresh package then makes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_offered_the_spent_package_is_said_to_miss_one_and_stays_owed() {
    use haven_core::relay::fanout::ReinviteResult;
    let (loser, _winner, _group, newcomer, spent) = an_owed_reinvite().await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    assert_eq!(
        only(driver.reinvite(&loser.circle, &finding(spent)).await),
        ReinviteResult::KeyPackageMissing,
        "MDK's refusal of the spent package was not said to be a missing package",
    );
    clock.set(5_000);
    let fresh =
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[INBOX.to_string()])
            .await;
    assert_eq!(
        only(driver.reinvite(&loser.circle, &finding(fresh)).await),
        ReinviteResult::Reissued,
        "a re-invite refused one package was not owed any more",
    );
}

/// A re-invite whose circle is not settled — not caught up in this session —
/// is not looked for: no relay is asked and no lookup of MDK's is spent, so
/// the first drive once it is settled looks at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_of_an_unsettled_circle_spends_no_lookup() {
    use haven_core::relay::fanout::ReinviteResult;
    let (loser, _winner, group, newcomer, _spent) = an_owed_reinvite().await;
    let loser = loser.reopen();
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let lookup = finding(
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[INBOX.to_string()])
            .await,
    );
    assert_eq!(
        only(driver.reinvite(&loser.circle, &lookup).await),
        ReinviteResult::Unsettled,
    );
    assert_eq!(
        lookup.asked.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "a relay was asked for a re-invite of a circle not caught up",
    );
    loser.session().mark_caught_up_for_test(&group);
    assert_eq!(
        only(driver.reinvite(&loser.circle, &lookup).await),
        ReinviteResult::Reissued,
        "the lookup a re-invite of an unsettled circle did not make was spent all the same",
    );
}

/// A re-invite owed into a circle whose routing id is another circle's on
/// this device too is not made: no relay is asked, no lookup is spent, and it
/// stays owed for when the hold ends with the circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_into_a_collided_circle_is_not_made_and_stays_owed() {
    let (loser, _winner, group, newcomer, _spent) = an_owed_reinvite().await;
    loser
        .session()
        .note_routing_collision_for_test(&group)
        .expect("the hold is noted");
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let lookup = finding(
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[INBOX.to_string()])
            .await,
    );
    assert!(
        driver.reinvite(&loser.circle, &lookup).await.is_empty()
            && lookup.asked.load(std::sync::atomic::Ordering::SeqCst) == 0
            && transport.calls().is_empty(),
        "an invite was made into a circle whose routing id is shared",
    );
    assert!(
        loser.session().owed_reinvite_count_for_test(&group).await == 1,
        "the re-invite a held circle owes was let go",
    );
}

/// A re-invite of a circle this device is no longer a member of names
/// nobody: no relay is asked, and MDK ends it on no key packages.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_of_a_circle_since_left_asks_no_relay() {
    use haven_core::relay::fanout::ReinviteResult;
    let (loser, winner, group, newcomer, _spent) = an_owed_reinvite().await;
    let (eviction, pending) = staged(
        &winner
            .session()
            .remove_members(&group, &[loser.pubkey_hex()])
            .await
            .expect("the other admin removes this one"),
    );
    winner
        .session()
        .confirm_published(pending)
        .await
        .expect("applied");
    let _ = loser
        .session()
        .process_event_settled_for_test(&eviction)
        .await;
    assert!(
        loser.session().removed_for_test(&group).await,
        "premise: this device is removed",
    );
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let lookup = finding(
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[INBOX.to_string()])
            .await,
    );
    assert_eq!(
        only(driver.reinvite(&loser.circle, &lookup).await),
        ReinviteResult::Ended,
    );
    assert!(
        lookup.asked.load(std::sync::atomic::Ordering::SeqCst) == 0
            && driver.reinvite(&loser.circle, &lookup).await.is_empty(),
        "a relay was asked for a re-invite of a circle this device left, or it is still owed",
    );
}

/// The route of a re-invite whose lookup was spent cannot be kept: it is
/// not made, said so — never "not due" — and MDK still owes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_whose_route_cannot_be_kept_is_said_unmade_and_stays_owed() {
    use haven_core::relay::fanout::ReinviteResult;
    let (loser, _winner, _group, newcomer, _spent) = an_owed_reinvite().await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let lookup = finding(
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[INBOX.to_string()])
            .await,
    );
    let store = helpers::removals::store(&loser);
    store
        .execute_batch("ALTER TABLE welcome_routes RENAME TO welcome_routes_unwritable;")
        .expect("the route cannot be kept");
    let unmade = only(driver.reinvite(&loser.circle, &lookup).await);
    store
        .execute_batch("ALTER TABLE welcome_routes_unwritable RENAME TO welcome_routes;")
        .expect("the route can be kept again");
    assert_eq!(unmade, ReinviteResult::Unmade);
    clock.set(5_000);
    assert_eq!(
        only(driver.reinvite(&loser.circle, &lookup).await),
        ReinviteResult::Reissued,
        "a re-invite whose route could not be kept was not owed any more",
    );
}

/// A re-invite whose newcomer lists no inbox relay Haven may dial is said
/// to lack one — no Welcome could reach them — and nothing is asked of MDK:
/// the re-invite stays owed for MDK's next lookup.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_whose_newcomer_lists_no_inbox_is_said_so_and_stays_owed() {
    use haven_core::relay::fanout::ReinviteResult;
    let (loser, _winner, _group, newcomer, _spent) = an_owed_reinvite().await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let package =
        helpers::create_key_package_event(newcomer.session(), &newcomer.keys, &[INBOX.to_string()])
            .await;
    let no_inbox = Lookup {
        found: Some(haven_core::circle::MemberKeyPackage {
            key_package_event: package.clone(),
            inbox_relays: Vec::new(),
            nip65_relays: Vec::new(),
        }),
        asked: std::sync::atomic::AtomicUsize::new(0),
    };
    assert_eq!(
        only(driver.reinvite(&loser.circle, &no_inbox).await),
        ReinviteResult::NoInbox,
    );
    assert!(
        transport.calls().is_empty() && outbox.handed().is_empty(),
        "something was sent for a re-invite with no inbox to reach",
    );
    clock.set(5_000);
    assert_eq!(
        only(driver.reinvite(&loser.circle, &finding(package)).await),
        ReinviteResult::Reissued,
        "a re-invite whose newcomer listed no inbox was not owed any more",
    );
}

/// Two admins remove the same member at the same epoch: whichever removal
/// branch selection withdrew asked for what is already so. It is deleted as
/// MDK's own re-issue would answer it (`AlreadySatisfied`), with nobody held
/// and nothing said — no notice tells the user a removal that happened was
/// dropped — and no relay called.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_removal_of_a_member_already_gone_is_satisfied_and_says_nothing() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (a, mut others, group) = split(fx);
    let b = others.remove(0);
    let named = others.remove(0).pubkey_hex();
    let by_a = a
        .session()
        .remove_members(&group, std::slice::from_ref(&named))
        .await
        .expect("a removes the member");
    let by_b = b
        .session()
        .remove_members(&group, std::slice::from_ref(&named))
        .await
        .expect("b removes the same member");
    cross(&a, &b, &group, &by_a, &by_b).await;
    // Both removals are privileged: the one whose committer sorts lower is
    // kept (MDK `convergence.rs` 138-146).
    let loser = if a.keys.public_key().to_bytes() > b.keys.public_key().to_bytes() {
        &a
    } else {
        &b
    };
    assert!(
        !roster(loser, &group).await.contains(&named),
        "premise: the member is gone on the kept branch",
    );
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let resumed = driver.resume(&loser.circle).await;
    let notes = loser.session().peek_change_notes(&group);
    assert!(
        resumed
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.kind == WithdrawnKind::RemoveMembers
                && change.outcome == WithdrawnOutcome::AlreadySatisfied),
        "a withdrawn removal whose member is gone was not answered as already so",
    );
    assert!(
        held(loser).is_empty()
            && !notes.contains(&ChangeNote::QueuedRemovalDropped)
            && !notes.contains(&ChangeNote::ChangeWithdrawn)
            && transport.calls().is_empty(),
        "a removal that happened was said to be dropped, held a member, or called a relay",
    );
    assert!(
        driver.resume(&loser.circle).await.withdrawn.is_empty(),
        "MDK's record of the satisfied removal was left to be found again",
    );
}

/// A withdrawn removal answered as already so keeps its member as taken out
/// while a reorg could still bring them back: when one does — a member who
/// saw neither removal makes a longer branch from before them — the member
/// is held again and the circle is told, as for any member a withdrawn commit
/// had taken out, never left on the roster unsaid.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_member_an_already_satisfied_removal_named_is_held_again_when_a_reorg_brings_them_back() {
    let fx = setup_circle(4, &[ONE]).await;
    co_admin(&fx).await;
    let (a, mut others, group) = split(fx);
    let b = others.remove(0);
    let named = others.remove(0).pubkey_hex();
    let c = others.remove(0);
    let by_a = a
        .session()
        .remove_members(&group, std::slice::from_ref(&named))
        .await
        .expect("a removes the member");
    let by_b = b
        .session()
        .remove_members(&group, std::slice::from_ref(&named))
        .await
        .expect("b removes the same member");
    // From the epoch both removals were made at, c makes a branch two commits
    // long, hearing neither.
    let mut longer = Vec::new();
    for _ in 0..2 {
        let (event, pending) = staged(
            &c.session()
                .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
                    group_id: group.clone(),
                })
                .await
                .expect("c updates itself"),
        );
        c.session()
            .confirm_published(pending)
            .await
            .expect("c's relays took it");
        longer.push(event);
    }
    cross(&a, &b, &group, &by_a, &by_b).await;
    let loser = if a.keys.public_key().to_bytes() > b.keys.public_key().to_bytes() {
        &a
    } else {
        &b
    };
    loser.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    assert!(
        driver
            .resume(&loser.circle)
            .await
            .withdrawn
            .iter()
            .any(|change| change.group_id == group
                && change.outcome == WithdrawnOutcome::AlreadySatisfied),
        "premise: the loser's removal was answered as already so",
    );
    assert!(held(loser).is_empty(), "premise: nobody is held");

    for event in &longer {
        let _ = loser.session().process_event_settled_for_test(event).await;
    }
    settled(loser, &group).await;
    assert!(
        roster(loser, &group).await.contains(&named),
        "premise: the longer branch, which never removed the member, was taken",
    );
    assert!(
        held(loser) == [named.clone()]
            && loser
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "a member brought back by a reorg after an already-satisfied removal was not held \
         and said",
    );
}

/// The user's removal is dropped as in
/// `a_fresh_own_removal_that_loses_to_a_removal_and_an_invite_back_is_dropped_and_held`,
/// and everything the screens read says so: the member is listed, the notice
/// names both the dropped removal and the withdrawn change, the circle's
/// recovery reads `RemovalUnmade`, and the member is the one a "Remove again"
/// is offered for. Once the notice is acknowledged nothing holds the circle,
/// and the next fix is sealed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_abandoned_removal_is_reported_and_the_member_is_shown_present() {
    use haven_core::relay::fanout::RecoveryCause;
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let (co, member) = (others.remove(0), others.remove(0));
    let named = member.pubkey_hex();
    confirmed(
        &admin,
        &admin
            .session()
            .remove_members(&group, std::slice::from_ref(&named))
            .await
            .expect("the user removes the member"),
    )
    .await;
    let removal = confirmed(
        &co,
        &co.session()
            .remove_members(&group, std::slice::from_ref(&named))
            .await
            .expect("the co-admin removes the member"),
    )
    .await;
    let invite_back = confirmed(&co, &invite(&co, &group, &member).await).await;
    for event in [&removal, &invite_back] {
        let _ = admin.session().process_event(event).await;
    }
    settled(&admin, &group).await;
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let _ = through(
        &transport,
        &Recorder::acking(true),
        &ManualClock::at(0),
        &FULL,
    )
    .resume(&admin.circle)
    .await;

    let shown = admin
        .circle
        .get_circle(&group)
        .await
        .expect("read")
        .expect("the circle");
    assert!(
        shown.members.iter().any(|listed| listed.pubkey == named),
        "the member a dropped removal named is not shown present"
    );
    let notice = admin.session().change_notice(&group);
    assert!(
        notice.notes.contains(&ChangeNote::QueuedRemovalDropped)
            && notice.notes.contains(&ChangeNote::ChangeWithdrawn),
        "the circle is not told its removal was dropped and its change withdrawn"
    );
    for foreground in [true, false] {
        assert_eq!(
            admin
                .circle
                .circle_recovery_for_test(&group, foreground)
                .await
                .expect("the recovery read"),
            Some(RecoveryCause::RemovalUnmade),
            "the circle's recovery does not name the unmade removal (foreground: {foreground})"
        );
    }
    assert_eq!(
        admin.session().unmade_removal_members(&group),
        Some(vec![named.clone()]),
        "the member a removal could be asked again for is not offered"
    );

    assert!(admin.session().acknowledge_change_notice(&group, &notice));
    assert_eq!(
        admin
            .circle
            .circle_recovery_for_test(&group, false)
            .await
            .expect("the recovery read"),
        None,
        "an acknowledged notice still holds the circle"
    );
    assert_eq!(
        admin.session().unmade_removal_members(&group),
        Some(Vec::new())
    );
    admin
        .circle
        .seal_location_for_test(
            &group,
            &haven_core::location::LocationMessage::new(4.0, 5.0),
        )
        .await
        .expect("the next fix is sealed");
}

/// After the drop above, a fourth member that was on the user's branch builds
/// two commits on it, and branch selection re-adopts the user's removal
/// (`GroupStateRevalidated`): the member is gone, nobody is held for it,
/// neither note stands untold, and nothing holds the circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_withdrawn_removal_revalidated_by_a_deeper_branch_shows_the_member_gone_and_takes_the_notice_back(
) {
    let fx = setup_circle(4, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let (co, member, witness) = (others.remove(0), others.remove(0), others.remove(0));
    let named = member.pubkey_hex();
    let own = confirmed(
        &admin,
        &admin
            .session()
            .remove_members(&group, std::slice::from_ref(&named))
            .await
            .expect("the user removes the member"),
    )
    .await;
    // The witness follows the user's branch.
    witness
        .session()
        .process_event_settled_for_test(&own)
        .await
        .expect("the witness applies the removal");
    let removal = confirmed(
        &co,
        &co.session()
            .remove_members(&group, std::slice::from_ref(&named))
            .await
            .expect("the co-admin removes the member"),
    )
    .await;
    let invite_back = confirmed(&co, &invite(&co, &group, &member).await).await;
    for event in [&removal, &invite_back] {
        let _ = admin.session().process_event(event).await;
    }
    settled(&admin, &group).await;
    admin.session().mark_caught_up_for_test(&group);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let _ = through(
        &transport,
        &Recorder::acking(true),
        &ManualClock::at(0),
        &FULL,
    )
    .resume(&admin.circle)
    .await;
    assert!(
        held(&admin) == [named.clone()],
        "premise: the dropped removal holds its member"
    );

    // Two commits on the user's branch, deeper than the co-admin's.
    for _ in 0..2 {
        let deeper = confirmed(
            &witness,
            &witness
                .session()
                .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
                    group_id: group.clone(),
                })
                .await
                .expect("the witness commits on the user's branch"),
        )
        .await;
        let _ = admin.session().process_event(&deeper).await;
        settled(&admin, &group).await;
    }
    assert!(
        !roster(&admin, &group).await.contains(&named),
        "premise: branch selection re-adopted the user's removal"
    );
    let notes = admin.session().peek_change_notes(&group);
    assert!(
        held(&admin).is_empty()
            && !notes.contains(&ChangeNote::QueuedRemovalDropped)
            && !notes.contains(&ChangeNote::ChangeWithdrawn),
        "a removal branch selection re-adopted is still told as dropped, or holds its member"
    );
    assert_eq!(
        admin
            .circle
            .circle_recovery_for_test(&group, false)
            .await
            .expect("the recovery read"),
        None,
        "a re-adopted removal still holds the circle"
    );
}
