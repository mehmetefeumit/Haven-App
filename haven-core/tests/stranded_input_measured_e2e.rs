//! What MDK v0.10.4 parks, and what becomes of it when its replay does not
//! run or does not finish — measured (`docs/MDK_UPSTREAM_TRACKER.md`
//! T-PARKED-REPLAY).
//!
//! While a commit of this device's own is pending the engine opens nothing
//! it is handed for that circle: every `kind:445` is stored as it arrived and
//! answered `Buffered`. Its replay alone reads such a row again — at the end
//! of a confirm, of a rollback and of a join. A row left `Retryable` and
//! unopened in a circle that holds no pending commit is therefore delivered
//! by nothing until one of those three happens: STRANDED. Each test here
//! reproduces one way a row gets there, on real engines, and pins what the
//! device then does; each goes red when MDK closes that way in, which is
//! the signal to delete what Haven does about it
//! (`tests/stranded_input_e2e.rs`).
//!
//! The measured device is the engine opened with no circle store behind it
//! ([`helpers::stranded::bare`]): the session Haven opens, less what Haven's
//! own store lets it do about a stranded row.

mod helpers;

use haven_core::nostr::mls::storage::{
    set_new_stored_message_fault_for_test, set_stored_message_write_fault_naming_for_test,
};
use haven_core::nostr::mls::types::{
    EpochId, EpochState, GroupId, HeldRowKind, HeldRowProbe, IngestOutcome, MessageState,
    OpenMlsContentKind, PendingStateRef, PublishWork, WelcomeAcceptance,
};
use haven_core::nostr::mls::SessionManager;
use helpers::drive::{epoch, has_fix, leave_of, reads, sealed_by, staged_ref, wait_out_the_engine};
use helpers::stranded::{
    a_stranded_leave, a_stranded_removal, a_stranded_rival, all_parked_at, answer, bare, co_admin,
    confirm_and_die, fixes, held, mls_db, parks, sealed_alone, served, split, stage_relays, staged,
    try_staged, unopened_retryable, Bare, ONE, THREE, TWO,
};
use helpers::{create_key_package_event, setup_circle};
use nostr::Event;

async fn stable(session: &SessionManager, group: &GroupId) -> bool {
    matches!(
        session.epoch_state(group).await,
        Some(EpochState::Stable { .. })
    )
}

// ── Ways in, for a fix ───────────────────────────────────────────────────────
//
// A kill after a CONFIRM's transaction is
// `finish_only_e2e.rs` `a_fix_parked_behind_a_pending_commit_is_stranded_by_a_kill_until_this_devices_next_confirm`.

/// A kill after a ROLLBACK's transaction. The engine discards the commit in
/// one transaction and replays what it parked after it (`publish.rs` 421-492,
/// 536); here the replay is failed at its first write, so nothing of the
/// first parked event is stored, and the process ends.
///
/// Both fixes stay parked — under the epoch the circle is STILL at, not an
/// earlier one. Nothing delivers them by itself: not the open, not an
/// advance, not the same events delivered again, which are answered
/// `Buffered`. This device's next own rollback in that circle delivers both,
/// in the order they arrived.
#[tokio::test]
async fn a_fix_parked_behind_a_commit_is_stranded_by_a_kill_after_the_rollbacks_transaction() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let (db, key) = mls_db(admin.dir.path());
    let source = epoch(&admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let first = sealed_by(&others[0], &group, 48.25).await;
    let second = sealed_by(&others[1], &group, 48.5).await;
    for fix in [&first, &second] {
        assert!(parks(admin.session(), fix).await, "premise: parked unread");
    }
    assert!(all_parked_at(
        &held(admin.session(), &group).await,
        2,
        source
    ));

    set_new_stored_message_fault_for_test(&db, &key, true).expect("arm");
    let rolled = admin.session().publish_failed(pending).await;
    set_new_stored_message_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        rolled.is_err() && staged_ref(&admin, &group).await.is_none(),
        "premise: the rollback's transaction landed and the call ended on an error",
    );

    let engine = bare(admin);
    assert_eq!(
        engine.session.epoch(&group).await.expect("epoch"),
        source,
        "premise: the commit was discarded",
    );
    assert!(
        all_parked_at(&held(&engine.session, &group).await, 2, source),
        "the engine replays what it parked when it opens, or stamps a parked row with \
         another epoch than the circle's own: update T-PARKED-REPLAY",
    );
    let advanced = served(&engine.session, &group).await;
    assert!(
        fixes(&advanced).is_empty(),
        "an advance delivers what the engine parked: update T-PARKED-REPLAY",
    );
    for fix in [&first, &second] {
        assert!(
            parks(&engine.session, fix).await,
            "the redelivery of a stranded event is no longer answered `Buffered`: update \
             T-PARKED-REPLAY and the rule in `relay::catchup::cursor_verdict`",
        );
    }

    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
    let rolled = engine
        .session
        .publish_failed(pending)
        .await
        .expect("a later rollback of this device's own");
    let delivered = fixes(&rolled);
    assert!(
        delivered.len() == 2
            && has_fix(&delivered[..1], &others[0], 48.25)
            && has_fix(&delivered[1..], &others[1], 48.5),
        "this device's next own rollback did not deliver what was stranded, once each and \
         in the order it arrived: update T-PARKED-REPLAY",
    );
    assert!(held(&engine.session, &group).await.is_empty());
}

/// The open's own clear of a staged commit. A commit found staged with no
/// record, that is not a removal, is cleared by the engine as it opens
/// (`engine.rs` 1976-2025), and what was parked behind it is replayed by
/// nothing. The open retires the cleared commit's row before any engine call
/// (T-KILL-WINDOW), so no later pass applies it: the circle stays at the
/// epoch the row is stored under, and the row is still parked and still
/// answered `Buffered`. This device's next own confirm delivers it.
#[tokio::test]
async fn a_fix_parked_behind_a_commit_the_open_clears_is_stranded() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let _ = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let parked = sealed_by(&others[0], &group, 48.25).await;
    assert!(
        parks(admin.session(), &parked).await,
        "premise: parked unread"
    );

    let engine = bare(admin);
    assert!(
        stable(&engine.session, &group).await,
        "premise: the open cleared the staged commit",
    );
    assert!(
        all_parked_at(&held(&engine.session, &group).await, 1, source)
            && parks(&engine.session, &parked).await,
        "the open's clear replays what was parked: update T-PARKED-REPLAY",
    );

    let advanced = served(&engine.session, &group).await;
    assert_eq!(
        engine.session.epoch(&group).await.expect("epoch"),
        source,
        "a later pass applied the commit the open cleared (T-KILL-WINDOW)",
    );
    assert!(
        fixes(&advanced).is_empty()
            && all_parked_at(&held(&engine.session, &group).await, 1, source)
            && parks(&engine.session, &parked).await,
        "a pass delivered the row parked behind the cleared commit, or left it answered \
         some other way: update T-PARKED-REPLAY",
    );

    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
    let confirmed = engine
        .session
        .confirm_published(pending)
        .await
        .expect("a later confirm of this device's own");
    assert!(
        has_fix(&fixes(&confirmed), &others[0], 48.25),
        "this device's next own confirm did not deliver what was stranded",
    );
    assert!(held(&engine.session, &group).await.is_empty());
}

/// No kill at all: a replayed row that errors ends the replay with the rows
/// behind it still parked (`message_processor/mod.rs` 3698-3706), after the
/// circle has already left `PendingPublish` — so the confirm cannot be asked
/// again. Here the engine opens the first parked fix, stores what it held,
/// and fails to re-state its row.
///
/// The fix the error struck WAS delivered (it is in the engine's buffer, and
/// a redelivery of it is a duplicate, though its row is still `Retryable`);
/// the one behind it is stranded exactly as a kill strands it, in a process
/// that is still running.
///
/// And the replay is HEAD OF LINE: while the same row goes on failing, this
/// device's next own confirm fails at it again and delivers nothing behind
/// it. A stranded row is delivered by the next own confirm only if every row
/// ahead of it replays.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_replayed_row_that_errors_strands_the_rows_behind_it_in_a_running_process() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let engine = bare(admin);
    let (db, key) = mls_db(engine.dir.path());
    let source = engine.session.epoch(&group).await.expect("epoch");
    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, TWO]).await;
    let struck = sealed_by(&others[0], &group, 48.25).await;
    let behind = sealed_by(&others[1], &group, 48.5).await;
    for fix in [&struck, &behind] {
        assert!(parks(&engine.session, fix).await, "premise: parked unread");
    }

    set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), true)
        .expect("arm");
    let confirmed = engine.session.confirm_published(pending).await;
    assert!(
        confirmed.is_err()
            && engine.session.epoch(&group).await.expect("epoch") == source + 1
            && stable(&engine.session, &group).await,
        "premise: the commit was applied, the circle left `PendingPublish`, and the confirm \
         ended on an error",
    );
    let left = fixes(&engine.session.drain().await);
    assert!(
        has_fix(&left, &others[0], 48.25) && !has_fix(&left, &others[1], 48.5),
        "premise: the replay delivered the row it reached and not the one behind it",
    );
    assert!(
        matches!(
            answer(&engine.session, &struck).await,
            IngestOutcome::Ignored { .. }
        ),
        "premise: the row the error struck was opened; its redelivery is a duplicate",
    );
    assert!(
        parks(&engine.session, &behind).await,
        "the row behind a replay error is no longer answered `Buffered`: update T-PARKED-REPLAY",
    );
    let advanced = served(&engine.session, &group).await;
    assert!(
        fixes(&advanced).is_empty()
            && all_parked_at(&held(&engine.session, &group).await, 2, source),
        "an advance delivered, or retired, what a replay error left parked",
    );

    // Head of line: the same row still fails.
    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
    let blocked = engine.session.confirm_published(pending).await;
    assert!(
        blocked.is_err()
            && !has_fix(&fixes(&engine.session.drain().await), &others[1], 48.5)
            && parks(&engine.session, &behind).await,
        "a later own confirm delivered a row parked behind one that still fails to replay: \
         the engine's replay is no longer head of line — update T-PARKED-REPLAY",
    );
    set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), false)
        .expect("disarm");

    let (_, pending) = stage_relays(&engine.session, &group, &[ONE]).await;
    let later = engine
        .session
        .confirm_published(pending)
        .await
        .expect("a later confirm of this device's own");
    assert!(
        has_fix(&fixes(&later), &others[1], 48.5),
        "this device's next own confirm did not deliver what the replay error left parked",
    );
    assert!(held(&engine.session, &group).await.is_empty());
}

/// A way in with NO pending commit anywhere: the engine's sweep of a
/// deferred row. A fix from an epoch this device has not reached is kept
/// `PeelDeferred`, which the engine sweeps by itself once the epoch is
/// reached. When the sweep's re-ingest of the row errors, the engine
/// re-states it `Retryable` (`message_processor/mod.rs` 2823-2827) — and a
/// `Retryable` row is one the sweep no longer lists. The fix is stranded
/// like any other, in a circle that never held a commit of this device's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deferred_row_whose_sweep_errors_is_stranded_with_no_pending_commit_involved() {
    let fx = setup_circle(3, &[ONE]).await;
    let leave = leave_of(&fx, 2).await;
    let (admin, others, group) = split(fx);
    let committer = &others[0];
    let engine = bare(admin);
    let (db, key) = mls_db(engine.dir.path());
    let source = engine.session.epoch(&group).await.expect("epoch");
    for session in [&engine.session, committer.session()] {
        assert!(matches!(
            answer(session, &leave).await,
            IngestOutcome::Processed
        ));
    }
    wait_out_the_engine(committer, &group).await;
    let advanced = committer
        .session()
        .stage_unrecorded_for_test(&group)
        .await
        .expect("the remaining member's advance runs");
    let (eviction, their_pending) = staged(&advanced);
    committer
        .session()
        .confirm_published(their_pending)
        .await
        .expect("the eviction is confirmed");
    let ahead = sealed_by(committer, &group, 11.5).await;
    assert!(
        matches!(
            answer(&engine.session, &ahead).await,
            IngestOutcome::TransportDeferred { .. }
        ),
        "premise: a fix from an epoch not yet reached is deferred",
    );
    assert!(matches!(
        answer(&engine.session, &eviction).await,
        IngestOutcome::Buffered { .. }
    ));

    // The pass applies the eviction; the sweep that follows re-ingests the
    // deferred fix and cannot store what it opens.
    set_new_stored_message_fault_for_test(&db, &key, true).expect("arm");
    for _ in 0..8 {
        let _ = engine.session.advance_for_receive(&group).await;
        if unopened_retryable(&held(&engine.session, &group).await) == 1 {
            break;
        }
        if let Some(wait) = engine.session.receive_retick_after(&group).await {
            tokio::time::sleep(wait).await;
        }
    }
    set_new_stored_message_fault_for_test(&db, &key, false).expect("disarm");
    assert_eq!(
        engine.session.epoch(&group).await.expect("epoch"),
        source + 1,
        "premise: the eviction was applied",
    );
    let rows = held(&engine.session, &group).await;
    assert!(
        unopened_retryable(&rows) == 1
            && rows
                .iter()
                .all(|row| row.state != MessageState::PeelDeferred),
        "a deferred row whose sweep errored is no longer re-stated `Retryable`: this way in \
         is closed — update T-PARKED-REPLAY",
    );
    assert!(
        stable(&engine.session, &group).await && parks(&engine.session, &ahead).await,
        "premise: no commit of this device's is pending, and the fix is answered `Buffered`",
    );
    let advanced = served(&engine.session, &group).await;
    assert!(
        !has_fix(&fixes(&advanced), committer, 11.5)
            && unopened_retryable(&held(&engine.session, &group).await) == 1,
        "the engine's sweep still reads a row it re-stated `Retryable`: update T-PARKED-REPLAY",
    );
}

// ── A parked commit ──────────────────────────────────────────────────────────

/// How a device left behind is brought back.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Heal {
    Rollback,
    Confirm,
}

/// A peer's commit made AFTER the circle applied this device's own: the
/// co-admin removes the third member at the next epoch, and that commit
/// arrives while this device's commit is still pending here. A kill after
/// the confirm's transaction strands it.
///
/// This device is then an epoch behind its circle and stays there: it cannot
/// read what the circle sends, and what it seals is sealed at an epoch THE
/// REMOVED MEMBER CAN READ. A device that makes no commit of its own never
/// leaves that state. Its next own rollback, or its next own confirm, takes
/// it to the circle's epoch — the confirm at the price of the change it
/// confirmed, which in this run loses to the commit the circle already
/// applied under both orders of the two committers' keys. That is the
/// fixture's doing, not the rule: the circle's branch holds an application
/// witness — the co-admin's fix sealed after its removal — and MDK compares
/// application witnesses before priority and committer
/// (`cgka-engine/src/convergence.rs` 138-146). With no such witness the lower
/// committer key decides, which this test does not measure.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_peers_commit_stranded_behind_a_confirm_leaves_this_device_sealing_for_a_removed_member()
{
    for (heal, admin_is_lower) in [
        (Heal::Rollback, true),
        (Heal::Confirm, true),
        (Heal::Confirm, false),
    ] {
        let (admin, peer, removed, group, source, theirs) =
            a_stranded_removal(admin_is_lower).await;
        let (peer, removed) = (&peer, &removed);
        let engine = bare(admin);
        assert!(
            engine.session.epoch(&group).await.expect("epoch") == source + 1
                && epoch(peer, &group).await == source + 2,
            "premise: this device applied its own commit and the circle moved on",
        );
        assert!(all_parked_at(
            &held(&engine.session, &group).await,
            1,
            source
        ));
        assert!(
            parks(&engine.session, &theirs).await,
            "the redelivery of a stranded commit is no longer answered `Buffered`",
        );

        // A device that makes no commit of its own: every deadline served,
        // and nothing changes.
        let _ = served(&engine.session, &group).await;
        assert!(
            engine.session.epoch(&group).await.expect("epoch") == source + 1
                && all_parked_at(&held(&engine.session, &group).await, 1, source),
            "an advance applied the stranded commit: update T-PARKED-REPLAY",
        );
        let later = sealed_by(peer, &group, 50.5).await;
        assert!(
            matches!(
                answer(&engine.session, &later).await,
                IngestOutcome::TransportDeferred { .. }
            ),
            "premise: what the circle sends after the stranded commit cannot be opened here",
        );
        let sealed = sealed_alone(&engine.session, &group).await;
        assert!(
            reads(removed, &sealed).await,
            "the removed member no longer reads what a device stranded behind its removal \
             seals: the confidentiality cost in T-PARKED-REPLAY has changed",
        );

        let (late, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
        match heal {
            Heal::Rollback => {
                engine
                    .session
                    .publish_failed(pending)
                    .await
                    .expect("a later rollback of this device's own");
            }
            Heal::Confirm => {
                engine
                    .session
                    .confirm_published(pending)
                    .await
                    .expect("a later confirm of this device's own");
                peer.session()
                    .process_event_settled_for_test(&late)
                    .await
                    .expect("the circle is handed the late commit");
            }
        }
        let _ = served(&engine.session, &group).await;
        assert_eq!(
            engine.session.epoch(&group).await.expect("epoch"),
            source + 2,
            "this device's next own rollback or confirm did not bring it to its circle's epoch",
        );
        assert_eq!(
            unopened_retryable(&held(&engine.session, &group).await),
            0,
            "the stranded commit is still parked",
        );
        assert_eq!(
            engine.session.group_relays(&group).await.expect("relays"),
            peer.session().group_relays(&group).await.expect("relays"),
            "after the heal the device and its circle are on two branches",
        );
        let after = sealed_by(peer, &group, 52.5).await;
        assert!(
            matches!(
                answer(&engine.session, &after).await,
                IngestOutcome::Processed
            ),
            "after the heal the device still cannot read its circle",
        );
        let sealed = sealed_alone(&engine.session, &group).await;
        assert!(
            reads(peer, &sealed).await && !reads(removed, &sealed).await,
            "after the heal the removed member still reads this device, or its circle cannot",
        );
    }
}

/// A RIVAL commit, stranded. When this device's commit is the one the circle
/// keeps, the stranded rival costs nothing but its row. When the rival is,
/// this device is alone on a branch of its own at the same epoch NUMBER: it
/// cannot read its circle and its circle's committer cannot read it. Its
/// next own rollback hands the rival to the engine, which then takes the
/// circle's branch.
#[tokio::test]
async fn a_rival_commit_stranded_behind_a_confirm_forks_this_device_when_the_rival_wins() {
    let mut forked = Vec::new();
    for stranded_is_lower in [true, false] {
        let (stranded, rival, group, source) = a_stranded_rival(stranded_is_lower).await;
        let engine = bare(stranded);
        assert!(all_parked_at(
            &held(&engine.session, &group).await,
            1,
            source
        ));
        let circle_relays = rival.session().group_relays(&group).await.expect("relays");
        let alone = engine.session.group_relays(&group).await.expect("relays") != circle_relays;
        forked.push(alone);
        let from_circle = sealed_by(&rival, &group, 60.5).await;
        let opened = matches!(
            answer(&engine.session, &from_circle).await,
            IngestOutcome::Processed
        );
        let sealed = sealed_alone(&engine.session, &group).await;
        assert_eq!(
            (opened, reads(&rival, &sealed).await),
            (!alone, !alone),
            "a device on a branch of its own reads its circle, or one on its circle's branch \
             does not",
        );

        let (_, pending) = stage_relays(&engine.session, &group, &[ONE]).await;
        engine
            .session
            .publish_failed(pending)
            .await
            .expect("a later rollback of this device's own");
        let _ = served(&engine.session, &group).await;
        assert_eq!(unopened_retryable(&held(&engine.session, &group).await), 0);
        assert_eq!(
            engine.session.group_relays(&group).await.expect("relays"),
            circle_relays,
            "this device's next own rollback did not bring it to its circle's branch",
        );
        let from_circle = sealed_by(&rival, &group, 62.5).await;
        let sealed = sealed_alone(&engine.session, &group).await;
        assert!(
            matches!(
                answer(&engine.session, &from_circle).await,
                IngestOutcome::Processed
            ) && reads(&rival, &sealed).await,
            "after the heal the device and its circle still cannot read each other",
        );
    }
    assert_eq!(
        forked,
        [false, true],
        "which of two commits from one epoch wins is no longer the lower committer key's: \
         the test no longer reaches both of its cases",
    );
}

// ── A parked leave ───────────────────────────────────────────────────────────

async fn pending_ref(session: &SessionManager, group: &GroupId) -> Option<PendingStateRef> {
    match session.epoch_state(group).await {
        Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
        _ => None,
    }
}

/// A device that was handed the eviction of a leave it held stranded, and
/// then rolled back a commit of its own. With premises asserted on the way:
/// the eviction names the leave by reference, a device that never opened the
/// leave cannot apply it, the engine sets it aside for good and a redelivery
/// of it is a duplicate; the device stays an epoch behind, sealing at an
/// epoch THE MEMBER WHO LEFT can read; the rollback's replay then opens the
/// leave, and the device schedules and commits an eviction of its own from
/// the epoch its circle has left, which the circle is handed.
///
/// Returns whether the device then reads its circle, and its circle it.
#[allow(clippy::too_many_lines)]
async fn a_rollback_behind_the_eviction_of_a_stranded_leave(admin_is_lower: bool) -> (bool, bool) {
    let (admin, others, group, source, eviction) = a_stranded_leave(admin_is_lower).await;
    let (committer, leaver) = (&others[0], &others[1]);
    let engine = bare(admin);
    assert!(
        all_parked_at(&held(&engine.session, &group).await, 1, source)
            && engine
                .session
                .eviction_due_after_for_test(&group)
                .await
                .is_none(),
        "premise: the leave is stranded, and this device schedules no eviction for it",
    );

    assert!(
        matches!(
            answer(&engine.session, &eviction).await,
            IngestOutcome::Buffered { .. }
        ),
        "premise: the eviction is taken up as a commit awaiting its pass",
    );
    let _ = served(&engine.session, &group).await;
    assert_eq!(
        engine.session.epoch(&group).await.expect("epoch"),
        source + 1,
        "a device holding the leave stranded applied the eviction that names it: the cost \
         of a stranded leave in T-PARKED-REPLAY has changed",
    );
    assert!(
        engine
            .session
            .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, source + 1)
            .await
            .expect("the eviction's row")
            .state
            == MessageState::EpochInvalidated,
        "premise: the engine set the eviction aside for good",
    );
    assert!(
        matches!(
            answer(&engine.session, &eviction).await,
            IngestOutcome::Ignored { .. }
        ),
        "premise: and a redelivery of it is a duplicate",
    );
    let sealed = sealed_alone(&engine.session, &group).await;
    assert!(
        reads(leaver, &sealed).await,
        "the member who left no longer reads what a device stranded behind its leave seals",
    );

    // The heal that works for a fix and for a commit: a later own rollback.
    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
    engine
        .session
        .publish_failed(pending)
        .await
        .expect("a later rollback of this device's own");
    assert!(
        held(&engine.session, &group)
            .await
            .iter()
            .any(|row| row.keeps == HeldRowKind::Opened(OpenMlsContentKind::Proposal)),
        "premise: the replay opened the leave",
    );
    // The engine's own eviction of the member who left, staged from the
    // epoch the circle has left, published and acknowledged.
    for _ in 0..8 {
        if let Some(wait) = engine.session.eviction_due_after_for_test(&group).await {
            tokio::time::sleep(wait).await;
        }
        // The full advance: a receive advance takes inputs only.
        let advanced = engine
            .session
            .stage_unrecorded_for_test(&group)
            .await
            .expect("the advance runs");
        let pending = match try_staged(&advanced) {
            Some((own, pending)) => {
                committer
                    .session()
                    .process_event_settled_for_test(&own)
                    .await
                    .expect("the circle is handed this device's eviction");
                Some(pending)
            }
            None => pending_ref(&engine.session, &group).await,
        };
        if let Some(pending) = pending {
            engine
                .session
                .confirm_published(pending)
                .await
                .expect("this device's own eviction is confirmed");
            break;
        }
    }
    let _ = served(&engine.session, &group).await;
    assert_eq!(
        (
            engine.session.epoch(&group).await.expect("epoch"),
            epoch(committer, &group).await
        ),
        (source + 2, source + 2),
        "premise: both stand at the same epoch number",
    );
    let from_circle = sealed_by(committer, &group, 34.5).await;
    let sealed = sealed_alone(&engine.session, &group).await;
    (
        matches!(
            answer(&engine.session, &from_circle).await,
            IngestOutcome::Processed
        ),
        reads(committer, &sealed).await,
    )
}

/// Once the eviction has been handed to a device holding the leave stranded,
/// the device's next own rollback does not bring it back to its circle. It
/// ends at the circle's epoch NUMBER on a branch of its own, and which of the
/// two evictions a circle keeps is decided by their committers' keys: with
/// the higher key this device is alone, reading nobody and read by nobody.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_stranded_behind_a_confirm_makes_the_eviction_that_names_it_unappliable_for_good() {
    assert_eq!(
        Box::pin(a_rollback_behind_the_eviction_of_a_stranded_leave(false)).await,
        (false, false),
        "a later rollback healed a device that had been handed the eviction of a leave it \
         held stranded: say so in T-PARKED-REPLAY",
    );
}

/// The same, with the lower key: this device's eviction is the one a circle
/// keeps, so the member handed it leaves the eviction it had applied for
/// this device's, and the two read each other again. The device is back with
/// its circle only because its circle came to it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rollback_behind_the_eviction_of_a_stranded_leave_wins_its_circle_over_with_the_lower_key(
) {
    assert_eq!(
        Box::pin(a_rollback_behind_the_eviction_of_a_stranded_leave(true)).await,
        (true, true),
        "the eviction a device commits behind a stranded leave no longer wins a circle \
         over with the lower key: say so in T-PARKED-REPLAY",
    );
}

/// The same stranded leave, drained BEFORE the eviction that names it
/// arrives: the eviction then applies like any other commit, and the device
/// is on its circle's epoch and reads it. What decides between this and the
/// test above is only which came first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stranded_leave_drained_before_its_eviction_arrives_costs_nothing() {
    let (admin, others, group, source, eviction) = a_stranded_leave(true).await;
    let (committer, leaver) = (&others[0], &others[1]);
    let engine = bare(admin);

    let (_, pending) = stage_relays(&engine.session, &group, &[ONE, THREE]).await;
    engine
        .session
        .publish_failed(pending)
        .await
        .expect("a later rollback of this device's own");
    let _ = answer(&engine.session, &eviction).await;
    let _ = served(&engine.session, &group).await;

    assert_eq!(
        engine.session.epoch(&group).await.expect("epoch"),
        source + 2
    );
    let from_circle = sealed_by(committer, &group, 34.5).await;
    let sealed = sealed_alone(&engine.session, &group).await;
    assert!(
        matches!(
            answer(&engine.session, &from_circle).await,
            IngestOutcome::Processed
        ) && reads(committer, &sealed).await
            && !reads(leaver, &sealed).await,
        "a leave drained before its eviction arrived still left the device out of step",
    );
}

// ── A re-join ────────────────────────────────────────────────────────────────

/// Confirms what `effects` staged on `session` and returns its event.
async fn confirmed(
    session: &SessionManager,
    effects: &haven_core::nostr::mls::types::SessionEffects,
) -> Event {
    let (event, pending) = staged(effects);
    session
        .confirm_published(pending)
        .await
        .expect("the commit is confirmed");
    event
}

/// The third caller of the engine's replay is a join. A device holding a
/// stranded fix is removed and invited back: the join's replay reads the row
/// and ends it — nothing is left parked and a redelivery is a duplicate —
/// and delivers nothing of it, because the new copy's epochs begin after the
/// one the fix was sealed in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rejoin_ends_a_stranded_row_and_delivers_nothing_of_it() {
    let fx = setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let group = fx.group.clone();
    let mut members = fx.members;
    let third = members.remove(2);
    let stranded = members.remove(1);
    let admin = members.remove(0);
    let source = epoch(&stranded, &group).await;
    let (mine, pending) = stage_relays(stranded.session(), &group, &[ONE, TWO]).await;
    let parked = sealed_by(&third, &group, 70.5).await;
    assert!(
        parks(stranded.session(), &parked).await,
        "premise: parked unread"
    );
    let engine: Bare = bare(confirm_and_die(stranded, pending, source + 1).await);
    assert!(all_parked_at(
        &held(&engine.session, &group).await,
        1,
        source
    ));
    admin
        .session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the admin applies the commit");

    let demotion = admin
        .session()
        .update_admin_policy(&group, &[admin.keys.public_key().to_bytes()])
        .await
        .expect("the demotion is staged");
    let demotion = confirmed(admin.session(), &demotion).await;
    let removal = admin
        .session()
        .remove_members(&group, &[engine.keys.public_key().to_hex()])
        .await
        .expect("the removal is staged");
    let removal = confirmed(admin.session(), &removal).await;
    for event in [&demotion, &removal] {
        engine
            .session
            .process_event_settled_for_test(event)
            .await
            .expect("the device sees its demotion and its removal");
    }
    assert!(
        !engine.session.group_is_live(&group).await
            && all_parked_at(&held(&engine.session, &group).await, 1, source),
        "premise: removed, and the stranded row still stored",
    );

    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let fresh = create_key_package_event(&engine.session, &engine.keys, &inbox).await;
    let invite = admin
        .session()
        .add_members(
            &group,
            vec![SessionManager::key_package_from_event(&fresh).expect("a key package")],
        )
        .await
        .expect("the device is invited back");
    let (welcome, pending) = invite
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution {
                welcomes, pending, ..
            } => Some((
                SessionManager::transport_message_to_event(&welcomes[0]).expect("a welcome"),
                *pending,
            )),
            _ => None,
        })
        .expect("the invite staged a commit with its Welcome");
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("confirmed");
    let Ok(WelcomeAcceptance::Ingested(joined)) = engine.session.accept_welcome(&welcome).await
    else {
        panic!("the device did not join again from its new Welcome");
    };
    assert!(
        engine.session.group_is_live(&group).await,
        "premise: joined"
    );
    assert!(
        held(&engine.session, &group).await.is_empty(),
        "a join no longer replays what the engine held parked: update T-PARKED-REPLAY",
    );
    assert!(
        !has_fix(&fixes(&joined.effects), &third, 70.5)
            && matches!(
                answer(&engine.session, &parked).await,
                IngestOutcome::Ignored { .. }
            ),
        "a join delivered a fix sealed before the new copy's first epoch, or left its \
         redelivery answered as anything but a duplicate",
    );
}

// ── What a healthy circle holds ──────────────────────────────────────────────

/// Every row a healthy circle legitimately keeps for a later attempt, beside
/// the one shape a stranded event has — transport bytes nobody opened,
/// stored `Retryable`, in a circle the open engine reports `Stable` and this
/// device is still in:
///
/// * a leave kept until its eviction: opened, `Created`;
/// * a fix from an epoch this device has not reached: unopened, but
///   `PeelDeferred` — the engine sweeps that state itself;
/// * a commit awaiting its pass: opened, `Created`;
/// * a fix parked behind a commit that is STILL pending, across a restart
///   under its record: unopened and `Retryable` — a stranded row's very
///   shape, under ANY epoch — in a circle the engine reports pending, whose
///   confirm or rollback will replay it;
/// * what a copy this device was removed from is handed: unopened and
///   `Retryable` too, in a circle this device no longer holds live; the
///   engine keeps those for a join.
///
/// So the row alone never says "stranded": the circle's state does, and
/// only the open engine knows it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn a_healthy_circles_rows_have_a_stranded_rows_shape_only_while_pending_or_removed() {
    let fx = setup_circle(3, &[ONE]).await;
    let leave = leave_of(&fx, 2).await;
    let (admin, others, group) = split(fx);
    let (peer, leaver) = (&others[0], &others[1]);
    let source = epoch(&admin, &group).await;

    assert!(matches!(
        answer(admin.session(), &leave).await,
        IngestOutcome::Processed
    ));
    let fix = sealed_by(peer, &group, 10.5).await;
    assert!(matches!(
        answer(admin.session(), &fix).await,
        IngestOutcome::Processed
    ));
    let rows = held(admin.session(), &group).await;
    assert!(
        rows.len() == 1
            && rows[0].keeps == HeldRowKind::Opened(OpenMlsContentKind::Proposal)
            && rows[0].state == MessageState::Created,
        "a kept leave is no longer one opened `Created` row, or a read fix left a row",
    );

    let _ = answer(peer.session(), &leave).await;
    wait_out_the_engine(peer, &group).await;
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
    assert!(matches!(
        answer(admin.session(), &ahead).await,
        IngestOutcome::TransportDeferred { .. }
    ));
    assert!(matches!(
        answer(admin.session(), &eviction).await,
        IngestOutcome::Buffered { .. }
    ));
    let rows = held(admin.session(), &group).await;
    assert!(
        rows.len() == 3
            && rows.contains(&HeldRowProbe {
                epoch: EpochId(source),
                state: MessageState::PeelDeferred,
                keeps: HeldRowKind::Unopened,
            })
            && rows.iter().any(|row| {
                row.keeps == HeldRowKind::Opened(OpenMlsContentKind::Commit)
                    && row.state == MessageState::Created
            })
            && unopened_retryable(&rows) == 0,
        "a fix from an epoch not yet reached, or a commit awaiting its pass, is kept in the \
         shape of a stranded row",
    );
    assert!(
        matches!(
            answer(admin.session(), &eviction).await,
            IngestOutcome::Ignored { .. }
        ),
        "a commit awaiting its pass is answered `Buffered` when delivered again: the cursor \
         rule can no longer tell it from a stranded row by that answer",
    );
    let _ = served(admin.session(), &group).await;
    assert!(
        held(admin.session(), &group).await.is_empty() && epoch(&admin, &group).await == source + 1,
        "premise: the pass applied the eviction and the engine swept the deferred fix",
    );

    // A pending commit under a record, a fix parked behind it, a restart.
    let recorded = admin
        .session()
        .update_relays_staging(
            &group,
            vec![ONE.to_owned(), TWO.to_owned()],
            1_700_000_000_000,
        )
        .await
        .expect("a relay change is staged under a record");
    assert_eq!(recorded.fanouts.len(), 1, "premise");
    let parked = sealed_by(peer, &group, 12.5).await;
    assert!(parks(admin.session(), &parked).await);
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && all_parked_at(&held(admin.session(), &group).await, 1, source + 1)
            && parks(admin.session(), &parked).await,
        "a fix parked behind a commit that is still pending under its record is no longer \
         one unopened `Retryable` row in a circle the engine reports pending",
    );

    // What a removed copy is handed.
    let _ = answer(leaver.session(), &eviction).await;
    let _ = served(leaver.session(), &group).await;
    let after = sealed_by(peer, &group, 13.5).await;
    assert!(
        matches!(
            answer(leaver.session(), &after).await,
            IngestOutcome::LocalState { .. }
        ) && !leaver.session().group_is_live(&group).await,
        "premise: the member who left is refused on its removed copy",
    );
    assert_eq!(
        unopened_retryable(&held(leaver.session(), &group).await),
        1,
        "what a removed copy is handed is no longer kept as one unopened `Retryable` row",
    );
}
