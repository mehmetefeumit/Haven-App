//! A circle that has ended on this device leaves no MLS state behind: its
//! leave forgets the group through MDK's `forget_group_local`, and so does
//! the sweep at the next open for a group a dead process left with no
//! circle. A disbanded group is never forgotten, and neither is one a
//! re-invite held unanswered may still need.
//!
//! Real MDK engines over `SQLCipher` stores; the transport is scripted, so no
//! socket is opened and no clock but the driver's own is waited on — save
//! the one wait for the wall clock's next second named where it is paid.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use haven_core::circle::{CircleError, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::openmls_group_keys_for_test;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    is_owned, DriveMode, LeaveStatus, LocationSeal, Publishing, LEAVE_BOUND_MS,
};
use helpers::drive::{through, ManualClock, Recorder};
use helpers::stranded::{mls_db, split};
use helpers::{create_key_package_event, setup_circle, CircleMember};
use nostr::JsonUtil as _;

const ONE: &str = "wss://one.left-canary4e8b.example.com";
const TWO: &str = "wss://two.left-canary4e8b.example.com";
const INBOX: &str = "wss://inbox.left-canary4e8b.example.com";
const FULL: DriveMode = DriveMode::Full;

/// Whether the engine of `member` still holds anything of `group`.
async fn holds(member: &CircleMember, group: &GroupId) -> bool {
    member.session().group_record(group).await.is_ok()
        || member
            .session()
            .live_group_ids()
            .await
            .expect("the groups are listed")
            .contains(group)
}

/// The `OpenMLS` group keys in `member`'s MLS store, read with the store
/// closed; `member` is given back reopened.
fn openmls_groups(member: CircleMember) -> (usize, CircleMember) {
    let (db, key) = mls_db(member.dir.path());
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    let groups = openmls_group_keys_for_test(&db, &key)
        .expect("the closed store is read")
        .len();
    let circle = std::sync::Arc::new(
        haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
            .expect("the stores reopen"),
    );
    (groups, CircleMember { circle, keys, dir })
}

/// A fresh `KeyPackage` of `member`'s, as an inviter holds it.
async fn package_of(member: &CircleMember) -> MemberKeyPackage {
    MemberKeyPackage {
        key_package_event: create_key_package_event(
            member.session(),
            &member.keys,
            &[INBOX.to_string()],
        )
        .await,
        inbox_relays: vec![INBOX.to_string()],
        nip65_relays: Vec::new(),
    }
}

/// The last event `transport` was handed.
fn last_sent(transport: &ScriptedFanout) -> nostr::Event {
    nostr::Event::from_json(
        transport
            .calls()
            .pop()
            .expect("premise: something was sent")
            .payload,
    )
    .expect("an event")
}

/// `admin` removes `member` from `group`, a relay acknowledging it; the
/// removal commit is handed back.
async fn removal_of(admin: &CircleMember, group: &GroupId, member: &CircleMember) -> nostr::Event {
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let removed = through(&transport, &outbox, &clock, &FULL)
        .remove_members(&admin.circle, group, &[member.pubkey_hex()])
        .await
        .expect("the removal is made");
    assert_eq!(
        removed.status,
        haven_core::relay::fanout::EvolutionStatus::Confirmed,
        "premise: the removal is applied",
    );
    last_sent(&transport)
}

/// `admin` invites `member` to `group`, a relay acknowledging the invite;
/// its Welcome's gift wrap is handed back.
async fn invite_of(admin: &CircleMember, group: &GroupId, member: &CircleMember) -> nostr::Event {
    let package = package_of(member).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .add_members(&admin.circle, group, &[package])
        .await
        .expect("the invite is made");
    outbox
        .handed()
        .into_iter()
        .map(|(event, _)| event)
        .find(|event| event.kind.as_u16() == 1059)
        .expect("premise: the Welcome was sent")
}

/// `member` presses Leave on `group`; its proposal is sent and never
/// acknowledged. The proposal is handed back.
async fn leave_pressed(
    driver: &Publishing<'_, ScriptedFanout>,
    transport: &ScriptedFanout,
    member: &CircleMember,
    group: &GroupId,
) -> nostr::Event {
    let pressed = driver
        .leave(&member.circle, group, &member.keys.public_key())
        .await
        .expect("the leave is accepted");
    assert_ne!(pressed.status, LeaveStatus::Completed, "premise");
    last_sent(transport)
}

/// A leave that ends at its bound, and the last member's leave of a circle
/// nobody else is in, each forget the circle's MLS group: the engine holds
/// nothing of it, its leave request and its records are gone, and the store
/// keeps no `OpenMLS` state of it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_left_circle_leaves_no_mls_state_behind() {
    // A leave nobody commits, ended at its bound.
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let proposal = leave_pressed(&driver, &transport, &member, &group).await;
    assert!(
        is_owned(&proposal.id) && member.session().leave_proposed_for_test(&group),
        "premise: the leave's proposal stands under its record",
    );
    clock.set(LEAVE_BOUND_MS);
    let ended = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert_eq!(ended.status, LeaveStatus::Completed);
    assert!(
        !holds(&member, &group).await,
        "a circle left at its bound kept its MLS group",
    );
    assert!(
        member
            .session()
            .fanout_ids_for_test(&group)
            .await
            .expect("read")
            .is_empty()
            && !is_owned(&proposal.id),
        "a left circle's leave record outlived it",
    );
    assert!(
        !member.session().leave_proposed_for_test(&group),
        "a left circle's leave request outlived it",
    );
    let (groups, _member) = openmls_groups(member);
    assert_eq!(
        groups, 0,
        "a left circle's OpenMLS state stayed on the device"
    );

    // The last member, abandoning the circle.
    let fx = setup_circle(1, &[ONE]).await;
    let (admin, _, group) = split(fx);
    let left = through(&transport, &outbox, &clock, &FULL)
        .leave(&admin.circle, &group, &admin.keys.public_key())
        .await
        .expect("the leave runs");
    assert_eq!(left.status, LeaveStatus::Completed);
    assert!(
        !holds(&admin, &group).await,
        "an abandoned circle kept its MLS group",
    );
    let (groups, _admin) = openmls_groups(admin);
    assert_eq!(groups, 0, "an abandoned circle's OpenMLS state stayed");
}

/// A circle MDK holds unrecoverable can send nothing — the engine refuses
/// every outbound intent on a halted group — so no proposal and no admin
/// hand-over can ever leave for it. Its leave ends at once on this device,
/// as one at its bound does, for an admin and for a member alike: the leave
/// succeeds, the circle's row is gone, its MLS group is forgotten, and
/// nothing is sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn leaving_an_unrecoverable_circle_ends_at_once_and_sends_nothing() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let leavers = [admin.halted(&group), others.remove(0).halted(&group)];
    for leaver in &leavers {
        let transport = ScriptedFanout::default();
        transport.answer(ONE, [Answer::Accepted]);
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        let left = through(&transport, &outbox, &clock, &FULL)
            .leave(&leaver.circle, &group, &leaver.keys.public_key())
            .await
            .expect("the leave of a halted circle succeeds");
        assert_eq!(
            left.status,
            LeaveStatus::Completed,
            "the leave of a halted circle did not end at once",
        );
        assert!(
            leaver.circle.get_circles().await.expect("read").is_empty(),
            "a halted circle's row outlived its leave",
        );
        assert!(
            !holds(leaver, &group).await,
            "a halted circle's MLS group outlived its leave",
        );
        assert!(
            transport.calls().is_empty() && outbox.handed().is_empty(),
            "the leave of a halted circle sent something",
        );
    }
}

/// A leave a peer committed — this device's copy marked removed — forgets
/// the group with its records: none of the leave's is left to send, the
/// relay layer no longer refuses its event, and a Welcome to the group
/// written before the forget can no longer join it (MDK's reset cutoff).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn forget_group_local_after_applied_leave_leaves_no_outstanding_fanout() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let proposal = leave_pressed(&driver, &transport, &member, &group).await;

    let removal = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    let _ = member
        .session()
        .process_event_settled_for_test(&removal)
        .await;
    assert!(
        member.session().removed_for_test(&group).await,
        "premise: this device's copy is marked removed",
    );
    let ended = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");

    assert_eq!(ended.status, LeaveStatus::Completed);
    assert!(!holds(&member, &group).await, "the removed copy was kept");
    assert!(
        member
            .session()
            .fanout_ids_for_test(&group)
            .await
            .expect("read")
            .is_empty()
            && member
                .session()
                .welcome_record_ids_for_test(&group)
                .await
                .expect("read")
                .is_empty()
            && !is_owned(&proposal.id),
        "a record of the left circle outlived the forget",
    );
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    assert!(
        matches!(
            member.circle.accept_invitation(&welcome.id).await,
            Err(CircleError::NeedsNewInvite)
        ),
        "a Welcome written before the forget joined the forgotten group",
    );
}

/// A removal this device saw only after its admin had already invited it
/// back: the re-invite, held unanswered when the leave ends, keeps the
/// group from being forgotten, so accepting it joins.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_written_before_the_removal_was_seen_still_joins() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _proposal = leave_pressed(&driver, &transport, &member, &group).await;

    let removal = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    // One catch-up: the re-invite and the removal arrive together.
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    let _ = member
        .session()
        .process_event_settled_for_test(&removal)
        .await;
    let ended = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert_eq!(ended.status, LeaveStatus::Completed);
    assert!(
        member
            .circle
            .get_circle(&group)
            .await
            .expect("read")
            .is_none(),
        "the leave did not end the circle at once",
    );

    let joined = member
        .circle
        .accept_invitation(&welcome.id)
        .await
        .expect("a re-invite written before the removal was seen joins");
    assert_eq!(joined.circle.mls_group_id, group);
    let sealed = driver
        .seal_location(&member.circle, &group, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("the seal runs")
        .seal;
    assert!(
        matches!(sealed, LocationSeal::Sealed { .. }),
        "the circle joined again cannot be shared with",
    );
}

/// A leave that ended at its bound, then a fresh invite accepted: the join
/// carries none of the old leave. MDK's replacement join keeps a standing
/// `LeaveRequest` (`cgka-engine/src/group_lifecycle.rs` 1108-1460), so only
/// the forget at the leave's end clears it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejoin_after_a_completed_leave_carries_no_stale_leave_request() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let _proposal = leave_pressed(&driver, &transport, &member, &group).await;
    clock.set(LEAVE_BOUND_MS);
    let ended = driver
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");
    assert_eq!(ended.status, LeaveStatus::Completed);

    // MDK refuses a Welcome whose rumor is not newer, in whole seconds, than
    // the forget: the invite is made once the wall clock has passed the
    // second the forget was made in. At most one second, and no race — the
    // outcome is fixed once that second has passed.
    let forgotten_by = nostr::Timestamp::now().as_secs();
    while nostr::Timestamp::now().as_secs() <= forgotten_by {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let _ = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    member
        .circle
        .accept_invitation(&welcome.id)
        .await
        .expect("the fresh invite joins");

    assert!(
        !member.session().leave_proposed_for_test(&group),
        "the joined circle still carries the old leave's request",
    );
    let sealed = driver
        .seal_location(&member.circle, &group, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("the seal runs")
        .seal;
    assert!(
        matches!(sealed, LocationSeal::Sealed { .. }),
        "the joined circle's sends are held as if it were being left",
    );
    // The next commit this device accepts proposes no leave of it.
    let third = CircleMember::new();
    let commit_transport = ScriptedFanout::default();
    commit_transport.answer(ONE, [Answer::Accepted]);
    let package = package_of(&third).await;
    let _ = through(&commit_transport, &outbox, &clock, &FULL)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is made");
    let commit = last_sent(&commit_transport);
    let before = transport.calls().len();
    let _ = driver
        .ingest_for_poll(&member.circle, &commit)
        .await
        .expect("the commit is taken in");
    assert_eq!(
        transport.calls().len(),
        before,
        "a commit accepted after the rejoin proposed the old leave again",
    );
    assert!(!member.session().leave_proposed_for_test(&group));
}

/// A process that died after the forget and before the circle's row went:
/// the next attempt finds no group to forget and ends the leave.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_between_the_forget_and_the_row_delete_completes_the_leave_at_the_next_resume() {
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = leave_pressed(
        &through(&transport, &outbox, &clock, &FULL),
        &transport,
        &member,
        &group,
    )
    .await;
    member
        .session()
        .forget_group_local(&group)
        .await
        .expect("the forget the dead process made");
    let member = member.reopen();
    assert!(
        member
            .circle
            .get_circles()
            .await
            .expect("read")
            .iter()
            .any(|kept| kept.circle.mls_group_id == group),
        "premise: the circle's row outlived the forget",
    );

    let ended = through(&transport, &outbox, &clock, &FULL)
        .resume_leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave carries on");

    assert_eq!(ended.status, LeaveStatus::Completed);
    assert!(member
        .circle
        .get_circle(&group)
        .await
        .expect("read")
        .is_none());
}

/// A group a dead process left behind with no circle — a create that never
/// saved its row — is forgotten by the first receive plane of the next
/// process. One whose row cannot be read is kept, and so is one made after
/// the open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_orphaned_group_is_forgotten_at_the_next_open() {
    let founder = CircleMember::new();
    let orphan = founder
        .session()
        .create_group(
            Vec::new(),
            haven_core::nostr::mls::LocationGroupConfig::new("Orphan").with_relays([ONE]),
        )
        .await
        .expect("the group is made")
        .group_id;
    let founder = founder.reopen();
    assert!(
        holds(&founder, &orphan).await,
        "premise: the orphan survived the restart"
    );

    // Its row unreadable: kept.
    let store = helpers::removals::store(&founder);
    store
        .execute_batch("ALTER TABLE circles RENAME TO circles_unread;")
        .expect("the circles table is hidden");
    founder.circle.recover_owed_outputs().await;
    assert!(
        holds(&founder, &orphan).await,
        "a group was forgotten on an unread row"
    );
    store
        .execute_batch("ALTER TABLE circles_unread RENAME TO circles;")
        .expect("the circles table is back");

    let founder = founder.reopen();
    let made_after_open = founder
        .session()
        .create_group(
            Vec::new(),
            haven_core::nostr::mls::LocationGroupConfig::new("Later").with_relays([ONE]),
        )
        .await
        .expect("the group is made")
        .group_id;
    founder.circle.recover_owed_outputs().await;

    assert!(
        !holds(&founder, &orphan).await,
        "a group no circle names outlived the next open",
    );
    assert!(
        holds(&founder, &made_after_open).await,
        "a group made after the open was swept",
    );
}

/// A consented join whose circle could not be written is still owed by the
/// engine at the next open: the sweep keeps its group, and the join becomes
/// the circle once its row can be written.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_owed_consented_join_is_never_swept() {
    let fx = setup_circle(1, &[ONE]).await;
    let (admin, _, group) = split(fx);
    let member = CircleMember::new();
    let welcome = invite_of(&admin, &group, &member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    helpers::removals::store(&member)
        .execute_batch(
            "CREATE TRIGGER memberships_refused BEFORE INSERT ON circle_memberships \
             BEGIN SELECT RAISE(ABORT, 'refused'); END;",
        )
        .expect("the membership write is refused");
    assert!(
        member.circle.accept_invitation(&welcome.id).await.is_err(),
        "premise: the accept's rows were not written",
    );
    // Nothing held is remembered across the restart either, as once a
    // replacement `KeyPackage` has been acknowledged: only the owed join
    // keeps the group.
    helpers::removals::store(&member)
        .execute(
            "DELETE FROM user_settings WHERE key = 'kp_held_invitation_outstanding_v1'",
            [],
        )
        .expect("the marker is cleared");

    let member = member.reopen();
    member.circle.recover_owed_outputs().await;
    assert!(
        holds(&member, &group).await,
        "the sweep forgot a join the user consented to",
    );

    helpers::removals::store(&member)
        .execute_batch("DROP TRIGGER memberships_refused;")
        .expect("the membership write is allowed again");
    let member = member.reopen();
    member.circle.recover_owed_outputs().await;
    assert!(
        member
            .circle
            .get_circle(&group)
            .await
            .expect("read")
            .is_some(),
        "the consented join never became its circle",
    );
}

/// `admin` commits a removal of `target` acknowledged by `ONE` and not by
/// `TWO`: it is applied, and its record still owes `TWO`. The commit is
/// handed back.
async fn a_removal_owing_a_relay(
    admin: &CircleMember,
    group: &GroupId,
    target: &CircleMember,
) -> nostr::Event {
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let made = through(&transport, &outbox, &clock, &FULL)
        .remove_members(&admin.circle, group, &[target.pubkey_hex()])
        .await
        .expect("the removal is made");
    assert_eq!(
        made.status,
        haven_core::relay::fanout::EvolutionStatus::Confirmed,
        "premise: applied on ONE's acknowledgement",
    );
    nostr::Event::from_json(
        transport
            .calls()
            .into_iter()
            .find(|call| call.target == ONE)
            .expect("premise: sent to ONE")
            .payload,
    )
    .expect("an event")
}

/// A co-admin whose applied commit still owes a relay, then removed from
/// the circle: the next drive — in the same process, or after a restart —
/// ends that record and sends nothing of it. A quarantined circle's records
/// are not touched: it is halted, and a retry brings it back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_fanout_rows_of_a_group_this_device_was_removed_from_are_deleted() {
    for restart in [false, true] {
        let fx = setup_circle(3, &[ONE, TWO]).await;
        helpers::stranded::co_admin(&fx).await;
        let (admin, mut others, group) = split(fx);
        let target = others.remove(1);
        let co = others.remove(0);
        let commit = a_removal_owing_a_relay(&co, &group, &target).await;
        let owed = co
            .session()
            .fanout_ids_for_test(&group)
            .await
            .expect("read");
        assert_eq!(
            owed.len(),
            1,
            "premise: the applied commit's record owes TWO"
        );
        let _ = admin
            .session()
            .process_event_settled_for_test(&commit)
            .await;
        let removal = removal_of(&admin, &group, &co).await;
        let _ = co.session().process_event_settled_for_test(&removal).await;
        assert!(co.session().removed_for_test(&group).await, "premise");
        let co = if restart { co.reopen() } else { co };

        let transport = ScriptedFanout::default();
        transport.answer(ONE, [Answer::Accepted]);
        transport.answer(TWO, [Answer::Accepted]);
        let outbox = Recorder::acking(true);
        let clock = ManualClock::at(0);
        let _ = through(&transport, &outbox, &clock, &FULL)
            .resume(&co.circle)
            .await;

        assert!(
            transport.calls().is_empty(),
            "a commit of a circle this device was removed from was sent (restart: {restart})",
        );
        assert!(
            co.session().fanout_ids_for_test(&group).await.expect("read").is_empty()
                && !is_owned(&commit.id),
            "the record of a circle this device was removed from outlived the drive (restart: {restart})",
        );
    }

    // Quarantined at the open: its record stays as it is stored.
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let proposal = leave_pressed(
        &through(&transport, &outbox, &clock, &FULL),
        &transport,
        &member,
        &group,
    )
    .await;
    let member = in_the_closed_store(member, |db, key| {
        let keys = openmls_group_keys_for_test(db, key).expect("read");
        assert_eq!(keys.len(), 1, "premise: one group");
        haven_core::nostr::mls::storage::delete_openmls_group_state_for_test(db, key, &keys[0])
            .expect("the group's OpenMLS state goes");
    });
    assert!(
        member
            .session()
            .quarantined_group_ids()
            .await
            .contains(&group),
        "premise: quarantined",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&member.circle)
        .await;
    let _member = in_the_closed_store(member, |db, key| {
        assert!(
            stored_fanouts(db, key).contains(&proposal.id.to_bytes().to_vec()),
            "a quarantined circle's record was deleted",
        );
    });
}

/// Runs `look` on `member`'s closed MLS store; `member` comes back reopened.
fn in_the_closed_store(
    member: CircleMember,
    look: impl FnOnce(&std::path::Path, &storage_sqlite::SqlCipherKey),
) -> CircleMember {
    let (db, key) = mls_db(member.dir.path());
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    look(&db, &key);
    let circle = std::sync::Arc::new(
        haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
            .expect("the stores reopen"),
    );
    CircleMember { circle, keys, dir }
}

/// The ids of every stored outbound fanout, read from a closed store with
/// nothing hidden.
fn stored_fanouts(db: &std::path::Path, key: &storage_sqlite::SqlCipherKey) -> Vec<Vec<u8>> {
    use cgka_traits::storage::OutboundFanoutStorage as _;
    haven_core::sqlcipher_init::ensure().expect("sqlite");
    let store = storage_sqlite::SqliteAccountStorage::open_encrypted_with_options(
        db,
        key,
        haven_core::nostr::mls::StorageConfig::storage_options(),
    )
    .expect("the closed store opens");
    store
        .list_outbound_fanouts()
        .expect("listed")
        .iter()
        .map(|row| row.message_id().as_slice().to_vec())
        .collect()
}

/// A Welcome accepted over this device's removed copy of its circle: the
/// copy's records — a leave proposal still standing — go with the join, so
/// nothing of the discarded branch is sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejoin_deletes_the_groups_fanout_rows() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let proposal = leave_pressed(
        &through(&transport, &outbox, &clock, &FULL),
        &transport,
        &member,
        &group,
    )
    .await;
    let removal = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    let _ = member
        .session()
        .process_event_settled_for_test(&removal)
        .await;
    assert!(
        member.session().removed_for_test(&group).await && is_owned(&proposal.id),
        "premise: the removed copy holds its leave's record",
    );

    member
        .circle
        .accept_invitation(&welcome.id)
        .await
        .expect("the Welcome joins over the removed copy");

    assert!(
        member
            .session()
            .fanout_ids_for_test(&group)
            .await
            .expect("read")
            .is_empty()
            && !is_owned(&proposal.id),
        "a record of the replaced copy survived the join",
    );

    // The consent arm: a still-active copy holding a location's record,
    // joined again on the user's press.
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let driver = through(&transport, &outbox, &clock, &FULL);
    let sealed = driver
        .seal_location(&member.circle, &group, &LocationMessage::new(48.85, 2.35))
        .await
        .expect("the seal runs")
        .seal;
    assert!(
        matches!(sealed, LocationSeal::Sealed { .. }),
        "premise: sealed"
    );
    assert!(
        !member
            .session()
            .location_records_for_test(&group)
            .await
            .expect("read")
            .is_empty(),
        "premise: the location's record stands",
    );
    let welcome = an_offer(&admin, &group, &member).await;
    let offers = member
        .circle
        .rejoin_offers_for_invitation(&welcome.id)
        .await
        .expect("the offer is shown");
    member
        .circle
        .confirm_group_rejoin(&welcome.id, &offers[0].local_state_token)
        .await
        .expect("the consent joins");
    assert!(
        member
            .session()
            .location_records_for_test(&group)
            .await
            .expect("read")
            .is_empty(),
        "a record of the copy the consent discarded survived the join",
    );
}

/// `admin` removes `member`, who never sees it, and invites them back:
/// accepted, the Welcome would replace `member`'s still-active copy, which
/// MDK does only on consent. The gift wrap is handed back, held.
async fn an_offer(admin: &CircleMember, group: &GroupId, member: &CircleMember) -> nostr::Event {
    let _ = removal_of(admin, group, member).await;
    let welcome = invite_of(admin, group, member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    assert!(
        matches!(
            member.circle.accept_invitation(&welcome.id).await,
            Err(CircleError::RejoinConfirmationRequired)
        ),
        "premise: the Welcome waits for consent",
    );
    welcome
}

/// A replacement Welcome is joined only on the user's consent, given to the
/// offer as it was shown: the offer names its inviter, a token from another
/// branch is refused with nothing changed, and the shown one joins — after a
/// restart between the offer and the press too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn replacement_welcome_requires_explicit_consent() {
    for restart in [false, true] {
        let fx = setup_circle(2, &[ONE]).await;
        let (admin, mut others, group) = split(fx);
        let member = others.remove(0);
        let welcome = an_offer(&admin, &group, &member).await;
        let member = if restart {
            let member = member.reopen();
            member
                .circle
                .process_gift_wrapped_invitation(&member.keys, &welcome)
                .await
                .expect("the invitation is polled back");
            member
        } else {
            member
        };
        let offers = member
            .circle
            .rejoin_offers_for_invitation(&welcome.id)
            .await
            .expect("the offer is shown");
        let [offer] = <[_; 1]>::try_from(offers).unwrap_or_else(|_| panic!("one offer"));
        assert_eq!(offer.group_id, group);
        assert_eq!(hex::encode(offer.welcomer.as_slice()), admin.pubkey_hex());
        let epoch_before = member.session().epoch(&group).await.expect("epoch");

        assert!(
            matches!(
                member
                    .circle
                    .confirm_group_rejoin(&welcome.id, &[0u8; 32])
                    .await,
                Err(CircleError::RejoinConfirmationRequired)
            ),
            "a token of another branch was taken as consent (restart: {restart})",
        );
        assert_eq!(
            member.session().epoch(&group).await.expect("epoch"),
            epoch_before,
            "a refused consent changed the copy",
        );
        let joined = member
            .circle
            .confirm_group_rejoin(&welcome.id, &offer.local_state_token)
            .await
            .expect("the consent joins");
        assert_eq!(joined.circle.mls_group_id, group);
        assert_eq!(
            member.session().epoch(&group).await.expect("epoch"),
            admin.session().epoch(&group).await.expect("epoch"),
            "the consent did not put the member on the inviter's branch (restart: {restart})",
        );
        let from_admin = helpers::drive::sealed_by(&admin, &group, 61.0).await;
        assert!(
            helpers::drive::reads(&member, &from_admin).await,
            "the rejoined member does not read the circle (restart: {restart})",
        );
        assert!(member
            .circle
            .get_pending_invitations()
            .expect("read")
            .is_empty());
    }
}

/// A declined replacement offer is never offered again: neither the offer
/// nor the invitation comes back, and the Welcome joins nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_declined_rejoin_is_never_offered_again() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let welcome = an_offer(&admin, &group, &member).await;

    member
        .circle
        .decline_group_rejoin(&welcome.id)
        .await
        .expect("declined");

    assert!(member
        .circle
        .get_pending_invitations()
        .expect("read")
        .is_empty());
    assert!(member
        .session()
        .rejoin_offers_for_test(&group)
        .await
        .is_empty());
    assert!(
        matches!(
            member
                .circle
                .process_gift_wrapped_invitation(&member.keys, &welcome)
                .await,
            Err(CircleError::AlreadyProcessed)
        ),
        "the declined invitation would be offered again",
    );
}

/// The card's own Decline, after the user opened the rejoin dialog and
/// cancelled it, takes the replacement offer with the invitation: MDK keeps
/// none of the replacement branch's state for a wrap nobody can answer any
/// more. Only that invitation's offer — another one from the same inviter
/// still stands, and can still be shown.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plain_decline_after_a_cancelled_rejoin_leaves_no_offer_and_spares_a_sibling() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let sibling = helpers::found_circle(&admin, &[&member], &[ONE]).await;
    let welcome = an_offer(&admin, &group, &member).await;
    let sibling_welcome = an_offer(&admin, &sibling, &member).await;
    let shown = member
        .circle
        .rejoin_offers_for_invitation(&welcome.id)
        .await
        .expect("the dialog shows the offer");
    assert_eq!(
        shown.len(),
        1,
        "premise: one offer, then the dialog is cancelled"
    );

    member
        .circle
        .decline_invitation(&welcome.id)
        .await
        .expect("declined");

    assert!(
        member
            .session()
            .rejoin_offers_for_test(&group)
            .await
            .is_empty(),
        "the declined invitation's replacement offer is still held",
    );
    assert!(
        matches!(
            member
                .circle
                .process_gift_wrapped_invitation(&member.keys, &welcome)
                .await,
            Err(CircleError::AlreadyProcessed)
        ),
        "the declined invitation would be offered again",
    );
    assert_eq!(
        member
            .session()
            .rejoin_offers_for_test(&sibling)
            .await
            .len(),
        1,
        "the decline took another invitation's offer from the same inviter",
    );
    let still = member
        .circle
        .rejoin_offers_for_invitation(&sibling_welcome.id)
        .await
        .expect("the sibling invitation is still held");
    assert_eq!(still.len(), 1, "the sibling's offer is no longer shown");
}

/// A commit the catch-up pager held back for a copy of a circle this device
/// then joins anew — a Welcome accepted over its removed copy, or a
/// replacement offer consented to — holds nothing of the new copy: that
/// commit belongs to a branch the join discarded, and nothing would ever
/// take it in, so the hold would keep the circle from sharing until a
/// restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pager_hold_from_before_a_rejoin_does_not_hold_the_rejoined_circle() {
    let stale = [nostr::EventId::all_zeros()];
    // A Welcome accepted over the removed copy.
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let removal = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    let _ = member
        .session()
        .process_event_settled_for_test(&removal)
        .await;
    member.session().hold_pager_commits_for_test(&group, &stale);
    assert!(
        member.session().holds_unread_input_for_test(&group),
        "premise: the pager holds a commit of the removed copy",
    );
    member
        .circle
        .accept_invitation(&welcome.id)
        .await
        .expect("the Welcome joins over the removed copy");
    assert!(
        !member.session().holds_unread_input_for_test(&group),
        "a commit held back for the removed copy holds the joined one",
    );

    // A replacement offer, consented to.
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let welcome = an_offer(&admin, &group, &member).await;
    member.session().hold_pager_commits_for_test(&group, &stale);
    let offers = member
        .circle
        .rejoin_offers_for_invitation(&welcome.id)
        .await
        .expect("the offer is shown");
    member
        .circle
        .confirm_group_rejoin(&welcome.id, &offers[0].local_state_token)
        .await
        .expect("the consent joins");
    assert!(
        !member.session().holds_unread_input_for_test(&group),
        "a commit held back for the discarded copy holds the rejoined one",
    );
    let sealed = through(
        &ScriptedFanout::default(),
        &Recorder::acking(true),
        &ManualClock::at(0),
        &FULL,
    )
    .seal_location(&member.circle, &group, &LocationMessage::new(48.85, 2.35))
    .await
    .expect("the seal runs")
    .seal;
    assert!(
        matches!(sealed, LocationSeal::Sealed { .. }),
        "the rejoined circle does not share",
    );
}

/// MDK announces a consented rejoin's `GroupJoined` in the batch AFTER the
/// confirm (`cgka-engine/src/group_lifecycle.rs` 1623; the session's confirm
/// collects no effects). A commit the pager holds back for the rejoined copy
/// after the confirm is that copy's own, and the late announcement must not
/// let it go: the circle seals nothing while it is held.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hold_the_rejoined_copy_takes_survives_the_late_join_announcement() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let welcome = an_offer(&admin, &group, &member).await;
    let offers = member
        .circle
        .rejoin_offers_for_invitation(&welcome.id)
        .await
        .expect("the offer is shown");
    member
        .circle
        .confirm_group_rejoin(&welcome.id, &offers[0].local_state_token)
        .await
        .expect("the consent joins");
    let fresh = [nostr::EventId::all_zeros()];
    member.session().hold_pager_commits_for_test(&group, &fresh);
    // The next engine batch, which carries the deferred announcement.
    let _ = member.session().settle_receive_for_test(&group).await;
    assert!(
        member.session().holds_unread_input_for_test(&group),
        "the late join announcement let go of a commit the rejoined copy holds back",
    );
}

/// MDK repairs a halted circle in place when an admin adds this device again
/// (`cgka-engine/src/group_lifecycle.rs` 1574-1590):
/// in the same session the circle reads live, the repair's gates no longer
/// call it terminal, and its roster is stamped again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejoined_unrecoverable_circle_reads_live_again_in_the_same_session() {
    use haven_core::circle::{CircleEngineState, DirectoryReconcile, DirectoryTier};
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0).halted(&group);
    let state = |member: &CircleMember| {
        let circle = std::sync::Arc::clone(&member.circle);
        let group = group.clone();
        async move {
            circle
                .get_circle(&group)
                .await
                .expect("read")
                .expect("the circle")
                .engine_state
        }
    };
    assert_eq!(
        state(&member).await,
        CircleEngineState::Unrecoverable,
        "premise: the circle reads halted"
    );
    let _ = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    // A halted copy is not a branch the user could be asked to keep: the
    // Welcome replaces it with no consent asked.
    member
        .circle
        .accept_invitation(&welcome.id)
        .await
        .expect("the Welcome repairs the halted copy");

    assert_eq!(
        state(&member).await,
        CircleEngineState::Live,
        "a circle the rejoin repaired still reads halted in this session"
    );
    let later = u64::try_from(chrono::Utc::now().timestamp()).expect("clock") + 25 * 60 * 60;
    assert!(
        !matches!(
            member
                .circle
                .repair_rotation_for_test(&group, later)
                .await
                .expect("the repair's answer")
                .0,
            haven_core::relay::fanout::RepairOutcome::Skipped(
                haven_core::circle::SkipReason::EpochUnrecoverable
            )
        ),
        "the repair still calls the rejoined circle terminal"
    );
    let now = chrono::Utc::now().timestamp();
    assert!(member
        .circle
        .reconcile_member_directory(DirectoryReconcile::Rewrite, now)
        .await
        .expect("the reconcile"));
    assert!(
        member
            .circle
            .ranked_directory_members(now)
            .expect("the directory")
            .iter()
            .any(|entry| entry.pubkey_hex == admin.pubkey_hex()
                && entry.tier == DirectoryTier::Current),
        "the rejoined circle's roster is not stamped"
    );
}

/// A replacement offer for a circle this device has asked to leave is
/// declined: the user's last word was to leave, and MDK's join would carry
/// the leave's request into the new branch.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejoin_offer_for_a_circle_being_left_is_declined() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = leave_pressed(
        &through(&transport, &outbox, &clock, &FULL),
        &transport,
        &member,
        &group,
    )
    .await;
    let welcome = an_offer(&admin, &group, &member).await;

    assert!(
        matches!(
            member
                .circle
                .rejoin_offers_for_invitation(&welcome.id)
                .await,
            Err(CircleError::NeedsNewInvite)
        ),
        "an offer for a circle being left was shown",
    );
    assert!(member
        .session()
        .rejoin_offers_for_test(&group)
        .await
        .is_empty());
    assert!(member
        .circle
        .get_pending_invitations()
        .expect("read")
        .is_empty());
}

/// `welcome`, opened with `invitee`'s keys and wrapped again by `sealer`:
/// the same MLS Welcome, from a seal author who did not write it.
async fn rewrapped(
    welcome: &nostr::Event,
    invitee: &nostr::Keys,
    sealer: &nostr::Keys,
) -> nostr::Event {
    use nostr::nips::nip44;
    let seal = nip44::decrypt(invitee.secret_key(), &welcome.pubkey, &welcome.content)
        .expect("the wrap opens");
    let seal = nostr::Event::from_json(seal).expect("a seal");
    let rumor =
        nip44::decrypt(invitee.secret_key(), &seal.pubkey, &seal.content).expect("the seal opens");
    let rumor: nostr::UnsignedEvent = nostr::UnsignedEvent::from_json(rumor).expect("a rumor");
    let forged = nostr::EventBuilder::new(rumor.kind, rumor.content.clone())
        .tags(rumor.tags.clone())
        .custom_created_at(rumor.created_at)
        .build(sealer.public_key());
    nostr::EventBuilder::gift_wrap(sealer, &invitee.public_key(), forged, [])
        .await
        .expect("wrapped again")
}

/// A Welcome whose MLS-authenticated author is not the inviter the
/// invitation showed is undone wherever the join is first seen: at the
/// accept, at an accept repeated after one that died, and at the open after
/// a process that died. The group is forgotten, no circle is written and
/// the invitation is resolved; an honest Welcome through the same paths
/// joins.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn welcomer_mismatch_forgets_group() {
    for arm in ["accept", "accepted again", "restart"] {
        for honest in [false, true] {
            let fx = setup_circle(1, &[ONE]).await;
            let (admin, _, group) = split(fx);
            let member = CircleMember::new();
            let welcome = invite_of(&admin, &group, &member).await;
            let stranger = nostr::Keys::generate();
            let welcome = if honest {
                welcome
            } else {
                rewrapped(&welcome, &member.keys, &stranger).await
            };
            let invitation = member
                .circle
                .process_gift_wrapped_invitation(&member.keys, &welcome)
                .await
                .expect("the invitation is held");
            let shown = if honest {
                admin.pubkey_hex()
            } else {
                stranger.public_key().to_hex()
            };
            assert_eq!(
                invitation.inviter_pubkey, shown,
                "premise: the seal author is shown"
            );

            let (member, accepted) = match arm {
                "accept" => {
                    let accepted = member.circle.accept_invitation(&welcome.id).await;
                    (member, accepted.map(|_| ()))
                }
                "accepted again" => {
                    member
                        .circle
                        .accept_and_die_for_test(&welcome.id)
                        .await
                        .expect("the engine joins");
                    let accepted = member.circle.accept_invitation(&welcome.id).await;
                    (member, accepted.map(|_| ()))
                }
                _ => {
                    member
                        .circle
                        .accept_and_die_for_test(&welcome.id)
                        .await
                        .expect("the engine joins");
                    let member = member.reopen();
                    member.circle.recover_owed_outputs().await;
                    (member, Ok(()))
                }
            };

            let recorded = member
                .circle
                .get_circle(&group)
                .await
                .expect("read")
                .is_some();
            if honest {
                assert!(
                    accepted.is_ok() && recorded && holds(&member, &group).await,
                    "an honest Welcome did not join ({arm})",
                );
                continue;
            }
            if arm != "restart" {
                assert!(
                    matches!(accepted, Err(CircleError::NeedsNewInvite)),
                    "a Welcome another author wrote was not refused ({arm})",
                );
            }
            assert!(
                !recorded && !holds(&member, &group).await,
                "a Welcome another author wrote left a circle or its group ({arm})",
            );
            assert!(
                member
                    .circle
                    .get_pending_invitations()
                    .expect("read")
                    .is_empty(),
                "the refused invitation is still offered ({arm})",
            );
            assert!(
                matches!(
                    member
                        .circle
                        .process_gift_wrapped_invitation(&member.keys, &welcome)
                        .await,
                    Err(CircleError::AlreadyProcessed)
                ),
                "the refused invitation would be offered again ({arm})",
            );
        }
    }
}

/// The forget leaves no key of the group behind (probe P-key of the R1
/// plan): MDK deletes a group's `OpenMLS` values by group key alone
/// (`storage-sqlite/src/storage/groups.rs` 210-214), and at this pin no leaf
/// key is held outside its group — not a joined member's, and not the new
/// one of an own commit staged and never merged. All that stays outside any
/// group is account-level: the MLS signing key pair and `KeyPackage`
/// bundles.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_forget_leaves_no_key_of_the_group_behind() {
    use haven_core::nostr::mls::storage::ungrouped_openmls_labels_for_test as ungrouped;
    let account_level = |labels: &[String]| {
        labels
            .iter()
            .all(|label| label == "SignatureKeyPair" || label == "KeyPackage")
    };

    // An unjoined KeyPackage is read where it is kept: the read sees labels.
    let fresh = CircleMember::new();
    let _ = package_of(&fresh).await;
    let _fresh = in_the_closed_store(fresh, |db, key| {
        assert!(
            ungrouped(db, key)
                .expect("read")
                .contains(&"KeyPackage".to_string()),
            "premise: the read finds what is kept under no group",
        );
    });

    // Joined, then forgotten.
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    member
        .session()
        .forget_group_local(&group)
        .await
        .expect("forgotten");
    let _member = in_the_closed_store(member, |db, key| {
        assert!(openmls_group_keys_for_test(db, key)
            .expect("read")
            .is_empty());
        assert!(
            account_level(&ungrouped(db, key).expect("read")),
            "a joined member's key outlived the forget"
        );
    });

    // A commit staged with a new leaf key, forgotten while it is pending.
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let package = package_of(&CircleMember::new()).await;
    let transport = ScriptedFanout::default();
    transport.answer(ONE, [Answer::Silent]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let staged = through(&transport, &outbox, &clock, &FULL)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is staged");
    assert_ne!(
        staged.status,
        haven_core::relay::fanout::EvolutionStatus::Confirmed,
        "premise: pending",
    );
    admin
        .session()
        .forget_group_local(&group)
        .await
        .expect("forgotten");
    let _admin = in_the_closed_store(admin, |db, key| {
        assert!(openmls_group_keys_for_test(db, key)
            .expect("read")
            .is_empty());
        assert!(
            account_level(&ungrouped(db, key).expect("read")),
            "a pending own commit's leaf key outlived the forget",
        );
    });
}

/// A disbanded circle is never forgotten: MDK's forget would delete the
/// tombstone that keeps it from being joined again
/// (`app-components/group-lifecycle-v1.md` 29-32). Leaving it ends the
/// circle's row and keeps the tombstone, and neither a later foreground
/// drive nor the next open's sweep forgets it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn leaving_a_disbanded_circle_keeps_its_tombstone() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    helpers::drive::disband(&admin, &group).await;

    admin
        .circle
        .complete_leave(&group, 0)
        .await
        .expect("the circle is left");
    assert!(admin.circle.get_circles().await.expect("read").is_empty());
    assert!(
        is_disbanded(&admin, &group).await,
        "leaving a disbanded circle forgot its tombstone"
    );
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&admin.circle)
        .await;
    let admin = admin.reopen();
    admin.circle.recover_owed_outputs().await;
    assert!(
        is_disbanded(&admin, &group).await,
        "a later drive or the next open forgot a disbanded circle's tombstone",
    );
}

/// Whether `member`'s engine holds `group` as disbanded: its tombstone.
async fn is_disbanded(member: &CircleMember, group: &GroupId) -> bool {
    member
        .session()
        .group_record(group)
        .await
        .is_ok_and(|record| record.disbanded.is_some())
}

/// A Welcome another author wrote, accepted over this device's removed copy
/// of the circle it names: the join is undone, and the circle's row — kept
/// since the removal — goes as at a leave, for nothing of that circle is left
/// on the device to show; wherever the join is first seen — the accept, an
/// accept repeated after one that died, the open after a process that died.
/// An honest Welcome over the same copy joins through each, and the circle
/// stays.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn a_welcomer_mismatch_over_a_removed_copy_ends_its_circle() {
    for arm in ["accept", "accepted again", "restart"] {
        for honest in [false, true] {
            let fx = setup_circle(2, &[ONE]).await;
            let (admin, mut others, group) = split(fx);
            let member = others.remove(0);
            let removal = removal_of(&admin, &group, &member).await;
            let welcome = invite_of(&admin, &group, &member).await;
            let welcome = if honest {
                welcome
            } else {
                rewrapped(&welcome, &member.keys, &nostr::Keys::generate()).await
            };
            let _ = member
                .session()
                .process_event_settled_for_test(&removal)
                .await;
            assert!(
                member.session().removed_for_test(&group).await && listed(&member, &group).await,
                "premise: a removed copy whose circle row is kept ({arm})",
            );
            member
                .circle
                .process_gift_wrapped_invitation(&member.keys, &welcome)
                .await
                .expect("the invitation is held");

            let (member, accepted) = match arm {
                "accept" => {
                    let accepted = member.circle.accept_invitation(&welcome.id).await;
                    (member, accepted.map(|_| ()))
                }
                "accepted again" => {
                    member
                        .circle
                        .accept_and_die_for_test(&welcome.id)
                        .await
                        .expect("the engine joins");
                    let accepted = member.circle.accept_invitation(&welcome.id).await;
                    (member, accepted.map(|_| ()))
                }
                _ => {
                    member
                        .circle
                        .accept_and_die_for_test(&welcome.id)
                        .await
                        .expect("the engine joins");
                    let member = member.reopen();
                    member.circle.recover_owed_outputs().await;
                    (member, Ok(()))
                }
            };

            if honest {
                assert!(
                    accepted.is_ok()
                        && holds(&member, &group).await
                        && listed(&member, &group).await,
                    "an honest Welcome over a removed copy did not join ({arm})",
                );
                assert!(
                    member
                        .session()
                        .pending_application_output_count_for_test()
                        .await
                        .expect("read")
                        == 0,
                    "the honest join was left owed ({arm})",
                );
                continue;
            }
            if arm != "restart" {
                assert!(
                    matches!(accepted, Err(CircleError::NeedsNewInvite)),
                    "a Welcome another author wrote was not refused ({arm})",
                );
            }
            assert!(
                !holds(&member, &group).await && !listed(&member, &group).await,
                "a Welcome another author wrote left the removed copy's circle or a group ({arm})",
            );
        }
    }
}

/// Whether `member`'s circle store lists `group`, whatever its engine holds.
async fn listed(member: &CircleMember, group: &GroupId) -> bool {
    member
        .circle
        .get_circles()
        .await
        .expect("read")
        .iter()
        .any(|kept| &kept.circle.mls_group_id == group)
}

/// A left circle whose group could not be read when its leave ended — kept,
/// never forgotten on a guess — is asked about again after a restart: once a
/// retry brings the group back, the next foreground drive forgets it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_left_circle_kept_unreadable_is_forgotten_once_readable_after_a_restart() {
    use haven_core::nostr::mls::storage::{
        restore_openmls_group_state_for_test, stash_openmls_group_state_for_test,
    };
    let fx = setup_circle(2, &[ONE]).await;
    let (_admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let member = in_the_closed_store(member, |db, key| {
        let keys = openmls_group_keys_for_test(db, key).expect("read");
        assert_eq!(keys.len(), 1, "premise: one group");
        stash_openmls_group_state_for_test(db, key, &keys[0]).expect("moved aside");
    });
    assert!(
        member
            .session()
            .quarantined_group_ids()
            .await
            .contains(&group),
        "premise: quarantined",
    );
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let left = through(&transport, &outbox, &clock, &FULL)
        .leave(&member.circle, &group, &member.keys.public_key())
        .await
        .expect("the leave runs");
    assert_eq!(left.status, LeaveStatus::Completed);
    assert!(
        !listed(&member, &group).await,
        "premise: the circle's row is gone"
    );

    let member = member.reopen();
    member.circle.recover_owed_outputs().await;
    let (db, key) = mls_db(member.dir.path());
    restore_openmls_group_state_for_test(&db, &key).expect("put back");
    assert!(
        member
            .session()
            .retry_quarantined_group(&group)
            .await
            .expect("retried"),
        "premise: the group is readable again",
    );
    let _ = through(&transport, &outbox, &clock, &FULL)
        .resume(&member.circle)
        .await;

    assert!(
        !holds(&member, &group).await,
        "a left circle kept while unreadable was never asked about again",
    );
}

/// After a restart, invitations held before it come back one poll at a
/// time, and a second restart before all of them did changes nothing. A left circle whose re-invite has not been polled back yet is kept
/// while another invitation already has: what is held in memory is not yet
/// everything that was held.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reinvite_not_yet_polled_back_after_a_restart_still_keeps_the_left_group() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let removal = removal_of(&admin, &group, &member).await;
    let reinvite = invite_of(&admin, &group, &member).await;
    let (stranger, _, elsewhere_group) = split(setup_circle(1, &[ONE]).await);
    let elsewhere = invite_of(&stranger, &elsewhere_group, &member).await;
    for invitation in [&reinvite, &elsewhere] {
        member
            .circle
            .process_gift_wrapped_invitation(&member.keys, invitation)
            .await
            .expect("held");
    }
    // Two restarts, the stranger's invitation polled back after each: the
    // second still knows the re-invite was held.
    let mut member = member;
    for _ in 0..2 {
        member = member.reopen();
        member
            .circle
            .process_gift_wrapped_invitation(&member.keys, &elsewhere)
            .await
            .expect("the stranger's invitation is polled back first");
    }
    let _ = member
        .session()
        .process_event_settled_for_test(&removal)
        .await;

    member
        .circle
        .complete_leave(&group, 0)
        .await
        .expect("the leave ends");

    assert!(
        holds(&member, &group).await,
        "a left group was forgotten while its re-invite had not been polled back",
    );
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &reinvite)
        .await
        .expect("the re-invite is polled back");
    member
        .circle
        .accept_invitation(&reinvite.id)
        .await
        .expect("the re-invite joins");
}

/// A key package replaced while nothing is held in memory ends the wait for
/// the invitations held before the restart — none of them can open the
/// package any more — so a later, unrelated invitation is all that is held:
/// it neither brings the old count back nor keeps a left group on a re-invite
/// that can no longer join.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_key_package_replaced_after_a_restart_ends_the_wait_for_what_was_held_before_it() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let removal = removal_of(&admin, &group, &member).await;
    let reinvite = invite_of(&admin, &group, &member).await;
    let (stranger, _, elsewhere_group) = split(setup_circle(1, &[ONE]).await);
    let elsewhere = invite_of(&stranger, &elsewhere_group, &member).await;
    for invitation in [&reinvite, &elsewhere] {
        member
            .circle
            .process_gift_wrapped_invitation(&member.keys, invitation)
            .await
            .expect("held");
    }
    let member = member.reopen();
    member.circle.note_key_package_replaced(false);
    let (later, _, later_group) = split(setup_circle(1, &[ONE]).await);
    let unrelated = invite_of(&later, &later_group, &member).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &unrelated)
        .await
        .expect("an unrelated invitation is held");
    let _ = member
        .session()
        .process_event_settled_for_test(&removal)
        .await;

    member
        .circle
        .complete_leave(&group, 0)
        .await
        .expect("the leave ends");

    assert!(
        !holds(&member, &group).await,
        "a left group was kept on an invitation held before a key package replacement",
    );
}

/// A replacement offer whose MLS-authenticated author is not the inviter
/// the invitation showed is never shown: it is declined with the invitation,
/// and nothing joins.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejoin_offer_whose_author_is_not_the_inviter_is_declined() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let _ = removal_of(&admin, &group, &member).await;
    let welcome = invite_of(&admin, &group, &member).await;
    let welcome = rewrapped(&welcome, &member.keys, &nostr::Keys::generate()).await;
    member
        .circle
        .process_gift_wrapped_invitation(&member.keys, &welcome)
        .await
        .expect("the invitation is held");
    assert!(
        matches!(
            member.circle.accept_invitation(&welcome.id).await,
            Err(CircleError::RejoinConfirmationRequired)
        ),
        "premise: the Welcome waits for consent",
    );
    let epoch_before = member.session().epoch(&group).await.expect("epoch");

    assert!(
        matches!(
            member
                .circle
                .rejoin_offers_for_invitation(&welcome.id)
                .await,
            Err(CircleError::NeedsNewInvite)
        ),
        "an offer another author wrote was shown",
    );
    assert!(member
        .session()
        .rejoin_offers_for_test(&group)
        .await
        .is_empty());
    assert_eq!(
        member.session().epoch(&group).await.expect("epoch"),
        epoch_before
    );
}

/// A consent given to an offer whose local branch moved after it was shown
/// — here a commit this co-admin staged meanwhile — is refused by MDK in the
/// replacement's own transaction, with nothing changed: the user is asked
/// again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_consent_the_local_branch_moved_under_is_refused_with_nothing_changed() {
    let fx = setup_circle(2, &[ONE]).await;
    // A co-admin, so the member can stage a commit of its own.
    helpers::stranded::co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let member = others.remove(0);
    let welcome = an_offer(&admin, &group, &member).await;
    let offers = member
        .circle
        .rejoin_offers_for_invitation(&welcome.id)
        .await
        .expect("the offer is shown");
    let _ = helpers::stranded::stage_relays(member.session(), &group, &[TWO]).await;
    let epoch_before = member.session().epoch(&group).await.expect("epoch");

    assert!(
        matches!(
            member
                .circle
                .confirm_group_rejoin(&welcome.id, &offers[0].local_state_token)
                .await,
            Err(CircleError::RejoinConfirmationRequired)
        ),
        "a consent to a branch that moved was taken",
    );
    assert_eq!(
        member.session().epoch(&group).await.expect("epoch"),
        epoch_before
    );
    assert!(
        !member
            .session()
            .rejoin_offers_for_test(&group)
            .await
            .is_empty(),
        "the offer was lost with the refused consent",
    );
}
