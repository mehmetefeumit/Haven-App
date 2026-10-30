//! The self-update (W13): the epoch-rotation repair any member may make, and
//! the one post-join self-update MDK records at every Welcome join, made by a
//! full drive after catch-up — and never by a wake, a timer or elapsed time.
//!
//! Real MDK engines over their own stores; "a kill" is the manager dropped
//! and the same stores opened again. The fanout transport is scripted
//! ([`ScriptedFanout`]) and sends nothing. Every instant the post-join reads
//! is the session's injectable clock (`set_legacy_clock_for_test`) and the
//! driver's is [`ManualClock`]; the only real time paid is the engine's own
//! convergence window where a peer applies a commit
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

mod helpers;

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{
    GroupId, IngestOutcome, LocationMessageResult, ScreenedIngest,
};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{
    DriveMode, FanoutClock, FanoutSend, ModeSource, ResumeOutcome, UnrecordedPublisher,
    RESTAGE_BASE_MS,
};
use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveDriver};
use helpers::drive::{through, ManualClock, Recorder, HOUR_MS, MINUTE_MS, SECOND_MS};
use helpers::{setup_circle, CircleFixture, CircleMember};
use nostr::{Event, JsonUtil as _};

const RELAY: &str = "wss://one.self-update-canary4b1e.example.com";

/// The session clock's origin: every instant the post-join reads is an
/// offset from here.
const T0: u64 = ManualClock::ORIGIN;

/// Past MDK's grace (15 s), quiet window (60 s) and the largest jitter it
/// samples (30 s).
const PAST_EVERY_WINDOW_MS: u64 = 15 * SECOND_MS + MINUTE_MS + 30 * SECOND_MS + 1;

/// One device's driver: the scripted transport, the publisher of what has no
/// record, and the driver's clock.
struct Driver {
    transport: std::sync::Arc<ScriptedFanout>,
    publisher: std::sync::Arc<Recorder>,
    clock: std::sync::Arc<ManualClock>,
    sent: std::sync::Mutex<Vec<Event>>,
}

impl Driver {
    fn accepting() -> Self {
        Self::answering(RELAY, &[Answer::Accepted])
    }

    /// `relay` answering each call in turn, the last answer repeating.
    fn answering(relay: &str, answers: &[Answer]) -> Self {
        let transport = ScriptedFanout::default();
        transport.answer(relay, answers.iter().copied());
        Self {
            transport: std::sync::Arc::new(transport),
            publisher: std::sync::Arc::new(Recorder::acking(true)),
            clock: ManualClock::at(0),
            sent: std::sync::Mutex::new(Vec::new()),
        }
    }

    /// A live plane over `member` on this driver.
    fn processor(&self, member: &CircleMember) -> EngineProcessor {
        EngineProcessor::with_driver(
            std::sync::Arc::clone(&member.circle),
            EventBus::new(),
            LiveDriver {
                fanout: std::sync::Arc::clone(&self.transport) as std::sync::Arc<dyn FanoutSend>,
                publisher: std::sync::Arc::clone(&self.publisher)
                    as std::sync::Arc<dyn UnrecordedPublisher>,
                clock: std::sync::Arc::clone(&self.clock) as std::sync::Arc<dyn FanoutClock>,
            },
        )
    }

    /// One resume of `member` in `mode`, with the session's clock and the
    /// driver's both at `offset_ms`.
    async fn resume(&self, member: &CircleMember, mode: &dyn ModeSource, offset_ms: u64) {
        let _ = self.resume_outcome(member, mode, offset_ms).await;
    }

    /// [`Self::resume`], with what it answered.
    async fn resume_outcome(
        &self,
        member: &CircleMember,
        mode: &dyn ModeSource,
        offset_ms: u64,
    ) -> ResumeOutcome {
        member.session().set_legacy_clock_for_test(T0 + offset_ms);
        self.clock.set(offset_ms);
        through(&self.transport, &self.publisher, &self.clock, mode)
            .resume(&member.circle)
            .await
    }

    /// The distinct events the transport was asked to send, oldest first.
    fn sent(&self) -> Vec<Event> {
        let mut seen = self.sent.lock().expect("sent");
        for call in self.transport.calls() {
            if seen.iter().all(|event| event.id != call.event_id) {
                seen.push(Event::from_json(&call.payload).expect("a sent event"));
            }
        }
        seen.clone()
    }
}

/// The joiner's post-join obligation phases.
async fn post_join_phases(member: &CircleMember, group: &GroupId) -> Vec<&'static str> {
    member
        .session()
        .obligations_for_test(group)
        .await
        .into_iter()
        .filter(|(trigger, _)| *trigger == "post_join")
        .map(|(_, phase)| phase)
        .collect()
}

async fn leaf(member: &CircleMember, group: &GroupId) -> Vec<u8> {
    member
        .session()
        .own_leaf_hash_for_test(group)
        .await
        .expect("the member's own leaf")
}

async fn epoch(member: &CircleMember, group: &GroupId) -> u64 {
    member.session().epoch(group).await.expect("epoch")
}

/// Whether `reader` decrypts a fix `sender` seals now.
async fn reads(
    sender: &CircleMember,
    reader: &CircleMember,
    group: &GroupId,
    latitude: f64,
) -> bool {
    let (event, _, _) = sender
        .circle
        .seal_location_for_test(group, &LocationMessage::new(latitude, 1.0))
        .await
        .expect("a seal");
    reader
        .circle
        .ingest_for_test(&event)
        .await
        .expect("an ingest")
        .iter()
        .any(|result| matches!(result, LocationMessageResult::Location { .. }))
}

/// Marks `member` caught up with the circle at `offset_ms`, as the end of a
/// sweep or of the live plane's stored events does.
fn caught_up_at(member: &CircleMember, group: &GroupId, offset_ms: u64) {
    member.session().set_legacy_clock_for_test(T0 + offset_ms);
    member.session().mark_caught_up_for_test(group);
}

fn joiner(fx: &CircleFixture) -> &CircleMember {
    &fx.members[1]
}

/// B joins. Full resumes before catch-up stage nothing; after it and MDK's
/// windows, exactly one self-update is staged under a record, confirmed on
/// the relay's acknowledgement, and it rotates B's leaf and completes the
/// obligation. A applies it, both read each other, and ten more resumes stage
/// nothing.
#[tokio::test]
async fn a_join_is_followed_by_exactly_one_self_update() {
    let fx = setup_circle(2, &[RELAY]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let driver = Driver::accepting();
    let joined_leaf = leaf(b, &fx.group).await;
    assert_eq!(
        post_join_phases(b, &fx.group).await,
        vec!["catch_up"],
        "premise: MDK recorded the joiner's post-join obligation"
    );
    assert!(
        post_join_phases(admin, &fx.group).await.is_empty(),
        "premise: the founder owes none"
    );

    for offset in [0, 10 * MINUTE_MS, 10 * 60 * MINUTE_MS] {
        driver.resume(b, &DriveMode::Full, offset).await;
    }
    assert!(
        driver.sent().is_empty(),
        "a full resume before the circle is caught up stages nothing"
    );

    let start = 11 * 60 * MINUTE_MS;
    caught_up_at(b, &fx.group, start);
    let early = driver
        .resume_outcome(b, &DriveMode::Full, start + SECOND_MS)
        .await;
    assert!(driver.sent().is_empty(), "nothing inside MDK's windows");
    assert!(
        early
            .retry_after_ms
            .is_some_and(|wait| wait <= PAST_EVERY_WINDOW_MS),
        "the resume asks to come back when the windows end"
    );

    let epoch_before = epoch(b, &fx.group).await;
    driver
        .resume(b, &DriveMode::Full, start + PAST_EVERY_WINDOW_MS)
        .await;
    let sent = driver.sent();
    assert_eq!(sent.len(), 1, "exactly one self-update was sent");
    assert_eq!(
        epoch(b, &fx.group).await,
        epoch_before + 1,
        "the relay's acknowledgement confirmed it"
    );
    assert_ne!(
        leaf(b, &fx.group).await,
        joined_leaf,
        "it rotated the joiner's Welcome leaf"
    );
    assert_eq!(post_join_phases(b, &fx.group).await, vec!["complete"]);

    admin
        .circle
        .ingest_for_test(&sent[0])
        .await
        .expect("the admin takes the self-update in");
    assert_eq!(epoch(admin, &fx.group).await, epoch_before + 1);
    assert!(reads(admin, b, &fx.group, 1.5).await);
    assert!(reads(b, admin, &fx.group, 2.5).await);

    for tick in 1..=10 {
        driver
            .resume(
                b,
                &DriveMode::Full,
                start + PAST_EVERY_WINDOW_MS + tick * 60 * MINUTE_MS,
            )
            .await;
    }
    assert_eq!(
        driver.sent().len(),
        1,
        "no further self-update is ever made"
    );
}

/// Drives `member`'s post-join self-update to its relay's acknowledgement:
/// caught up at `start`, then one full resume past MDK's windows. Returns
/// the commit, for the peers to take in.
async fn settle_post_join(
    driver: &Driver,
    member: &CircleMember,
    group: &GroupId,
    start: u64,
) -> Event {
    let before = driver.sent().len();
    caught_up_at(member, group, start);
    driver
        .resume(member, &DriveMode::Full, start + PAST_EVERY_WINDOW_MS)
        .await;
    let sent = driver.sent();
    assert_eq!(
        sent.len(),
        before + 1,
        "premise: the post-join self-update was made"
    );
    sent.last().cloned().expect("the self-update")
}

/// A self-update a kill left staged with no record — the engine wrote its
/// durable evolution, the process died before Haven's record — is cleared at
/// the open: no evolution, nothing pending, nothing handed out to publish,
/// and the user told nothing, because nobody asked for it. The obligation is
/// still open, and the next caught-up full resume makes a fresh one.
#[tokio::test]
async fn a_self_update_a_kill_left_without_its_record_is_cleared_at_the_open_and_made_again() {
    let mut fx = setup_circle(2, &[RELAY]).await;
    let group = fx.group.clone();
    let b = fx.members.remove(1);
    let joined_leaf = leaf(&b, &group).await;
    b.session()
        .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
            group_id: group.clone(),
        })
        .await
        .expect("the engine stages a self-update and nothing records it");
    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        1,
        "premise: the engine wrote the self-update's durable evolution"
    );

    // The open's clear, under in-process log capture: it names nothing.
    let mut reopened = None;
    let lines = helpers::capture_haven_log(async {
        reopened = Some(b.reopen());
    })
    .await;
    let b = reopened.expect("the member reopened");
    helpers::assert_some_line_from(&lines, "haven_core");
    helpers::assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[
            hex::encode(group.as_slice()).as_str(),
            b.pubkey_hex().as_str(),
            RELAY,
        ],
    );
    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        0,
        "no self-update evolution survives the open without its record"
    );
    assert!(
        matches!(
            b.session().epoch_state(&group).await,
            Some(haven_core::nostr::mls::types::EpochState::Stable { .. })
        ),
        "nothing is left pending: the hydrate cleared the commit"
    );
    let driver = Driver::accepting();
    driver.resume(&b, &DriveMode::Full, 0).await;
    assert!(
        driver.sent().is_empty() && driver.publisher.handed().is_empty(),
        "nothing the open restored is handed out to be published"
    );
    assert_eq!(leaf(&b, &group).await, joined_leaf);
    assert!(
        !b.session()
            .peek_change_notes(&group)
            .contains(&haven_core::nostr::mls::ChangeNote::ChangeUndone),
        "nobody asked for the post-join self-update, so nobody is told it was undone"
    );
    assert_eq!(post_join_phases(&b, &group).await, vec!["catch_up"]);

    let commit = settle_post_join(&driver, &b, &group, MINUTE_MS).await;
    assert_ne!(
        leaf(&b, &group).await,
        joined_leaf,
        "a fresh self-update was made"
    );
    assert_eq!(post_join_phases(&b, &group).await, vec!["complete"]);
    assert!(
        !b.session()
            .peek_change_notes(&group)
            .contains(&haven_core::nostr::mls::ChangeNote::ChangeUndone),
        "nor once the engine's announcement of the clear has been read"
    );
    fx.admin()
        .circle
        .ingest_for_test(&commit)
        .await
        .expect("the admin takes it in");
    assert!(reads(&b, fx.admin(), &group, 3.5).await);
}

/// The same kill inside the user's repair: the repair's mark is still
/// standing at the open, so the user IS told their repair was undone, and
/// the mark ends with the open.
#[tokio::test]
async fn a_repair_a_kill_left_without_its_record_is_told_undone_at_the_open() {
    let mut fx = setup_circle(2, &[RELAY]).await;
    let group = fx.group.clone();
    let b = fx.members.remove(1);
    assert!(b.session().mark_repair_for_test(&group));
    b.session()
        .send(haven_core::nostr::mls::types::SendIntent::SelfUpdate {
            group_id: group.clone(),
        })
        .await
        .expect("the engine stages the repair and nothing records it");

    let b = b.reopen();
    assert_eq!(b.session().repair_marked_for_test(&group), Some(false));
    let driver = Driver::accepting();
    driver.resume(&b, &DriveMode::Full, 0).await;
    assert!(
        b.session()
            .peek_change_notes(&group)
            .contains(&haven_core::nostr::mls::ChangeNote::ChangeUndone),
        "the user asked for the repair, so they are told it was undone"
    );
}

/// Two members repair at one epoch and take each other's commit in: both
/// settle on one epoch and one roster and read each other. Neither repairs
/// again on its own, and no full resume makes another self-update.
#[tokio::test]
async fn two_members_repairing_at_once_converge_on_one_branch() {
    let fx = setup_circle(2, &[RELAY]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let driver = Driver::accepting();
    let post_join = settle_post_join(&driver, b, &fx.group, 0).await;
    admin
        .circle
        .ingest_for_test(&post_join)
        .await
        .expect("ingest");
    let start = epoch(admin, &fx.group).await;

    // A day and more past the post-join's epoch change, so gate 3 is open.
    let later = u64::try_from(chrono::Utc::now().timestamp()).expect("clock") + 25 * 60 * 60;
    let (_, Some(from_admin)) = admin
        .circle
        .repair_rotation_for_test(&fx.group, later)
        .await
        .expect("the admin's repair")
    else {
        panic!("the admin repairs");
    };
    let (_, Some(from_b)) = b
        .circle
        .repair_rotation_for_test(&fx.group, later)
        .await
        .expect("the joiner's repair")
    else {
        panic!("the joiner repairs");
    };
    admin
        .circle
        .ingest_landing_for_test(&from_b)
        .await
        .expect("ingest");
    b.circle
        .ingest_landing_for_test(&from_admin)
        .await
        .expect("ingest");

    assert_eq!(epoch(admin, &fx.group).await, start + 1);
    assert_eq!(
        epoch(b, &fx.group).await,
        start + 1,
        "one branch, one epoch"
    );
    assert_eq!(
        drive_roster(admin, &fx.group).await,
        drive_roster(b, &fx.group).await
    );
    assert!(reads(admin, b, &fx.group, 4.5).await);
    assert!(reads(b, admin, &fx.group, 5.5).await);

    // Asked again at the device's real clock, as the app asks: the epoch
    // change both just applied holds it.
    let now = u64::try_from(chrono::Utc::now().timestamp()).expect("clock");
    for (who, member) in [("admin", admin), ("joiner", b)] {
        assert!(
            matches!(
                member
                    .circle
                    .repair_rotation_for_test(&fx.group, now)
                    .await
                    .expect("outcome")
                    .0,
                haven_core::relay::fanout::RepairOutcome::Skipped(_)
            ),
            "{who}'s repair is not made again: the epoch change and the rate limit hold it"
        );
    }
    let sent = driver.sent().len();
    for tick in 1..=5 {
        driver
            .resume(
                b,
                &DriveMode::Full,
                PAST_EVERY_WINDOW_MS + tick * 60 * MINUTE_MS,
            )
            .await;
    }
    assert_eq!(
        driver.sent().len(),
        sent,
        "no full resume makes another self-update"
    );
}

async fn drive_roster(member: &CircleMember, group: &GroupId) -> Vec<String> {
    helpers::drive::roster(member, group).await
}

/// B's post-join self-update is confirmed, then the admin's removal from the
/// same epoch arrives: privileged, it wins, and B's leaf is back at its
/// Welcome leaf. The obligation opens again and B's next full resume, once
/// the quiet window after that epoch change has passed, makes a fresh one.
/// In a second circle a repair B makes first completes the obligation, and
/// no post-join self-update follows it.
#[tokio::test]
async fn a_lost_post_join_self_update_is_made_again_and_a_repair_satisfies_it() {
    let fx = setup_circle(3, &[RELAY]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let joined_leaf = leaf(b, &fx.group).await;
    let driver = Driver::accepting();
    let lost = settle_post_join(&driver, b, &fx.group, 0).await;
    assert_eq!(post_join_phases(b, &fx.group).await, vec!["complete"]);

    // The admin, not having seen it, removes the third member from the same
    // epoch.
    let removal = admin
        .circle
        .remove_members_for_test(&fx.group, &[fx.members[2].pubkey_hex()])
        .await
        .expect("the admin's removal");
    let at = PAST_EVERY_WINDOW_MS + MINUTE_MS;
    b.session().set_legacy_clock_for_test(T0 + at);
    b.circle
        .ingest_landing_for_test(&removal)
        .await
        .expect("ingest");
    assert_eq!(
        leaf(b, &fx.group).await,
        joined_leaf,
        "premise: the privileged removal won, and took B's self-update back"
    );
    driver.resume(b, &DriveMode::Full, at + SECOND_MS).await;
    assert_eq!(
        post_join_phases(b, &fx.group).await,
        vec!["catch_up"],
        "the obligation opens again"
    );
    let before = driver.sent().len();
    driver
        .resume(b, &DriveMode::Full, at + PAST_EVERY_WINDOW_MS)
        .await;
    let sent = driver.sent();
    assert_eq!(sent.len(), before + 1, "a fresh self-update is made");
    assert_ne!(sent.last().map(|event| event.id), Some(lost.id));
    assert_ne!(leaf(b, &fx.group).await, joined_leaf);
    assert_eq!(post_join_phases(b, &fx.group).await, vec!["complete"]);

    // A repair made first satisfies the obligation.
    let other = setup_circle(2, &[RELAY]).await;
    let c = joiner(&other);
    let later = u64::try_from(chrono::Utc::now().timestamp()).expect("clock") + 25 * 60 * 60;
    let (_, Some(_)) = c
        .circle
        .repair_rotation_for_test(&other.group, later)
        .await
        .expect("the joiner's repair")
    else {
        panic!("the joiner repairs");
    };
    let second = Driver::accepting();
    caught_up_at(c, &other.group, 0);
    for tick in 1..=4 {
        second
            .resume(c, &DriveMode::Full, tick * PAST_EVERY_WINDOW_MS)
            .await;
    }
    assert!(
        second.sent().is_empty(),
        "no post-join self-update follows the repair"
    );
    assert_eq!(post_join_phases(c, &other.group).await, vec!["complete"]);
}

/// B is removed before its self-update is due: the obligation fails and
/// nothing is staged.
#[tokio::test]
async fn a_removed_joiner_never_self_updates() {
    let fx = setup_circle(2, &[RELAY]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let removal = admin
        .circle
        .remove_members_for_test(&fx.group, &[b.pubkey_hex()])
        .await
        .expect("the admin removes B");
    b.circle.ingest_for_test(&removal).await.expect("ingest");
    let driver = Driver::accepting();
    caught_up_at(b, &fx.group, 0);
    for tick in 1..=3 {
        driver
            .resume(b, &DriveMode::Full, tick * PAST_EVERY_WINDOW_MS)
            .await;
    }
    assert!(
        driver.sent().is_empty(),
        "a removed joiner makes no self-update"
    );
    assert_eq!(post_join_phases(b, &fx.group).await, vec!["failed"]);
}

/// A clock offset, on [`ManualClock`], at the device's real time plus a day
/// and an hour: past every repair gate a fresh circle stamps in real time.
fn repair_clock_offset() -> u64 {
    let real_ms = u64::try_from(chrono::Utc::now().timestamp_millis()).expect("clock");
    real_ms + 25 * 60 * MINUTE_MS - ManualClock::ORIGIN
}

/// (a) The self-update is staged and no relay answers; after a restart the
/// record is restored, the same bytes are sent again, the acknowledgement
/// completes the obligation, and exactly one self-update evolution exists.
/// (b) The circle holds a commit of B's own when the self-update falls due:
/// nothing is staged, the obligation stays open across a restart, and the
/// first resume after the circle is stable again makes it.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_join_during_pending_publish_still_self_updates_after_restart() {
    // (a)
    let mut fx = setup_circle(2, &[RELAY]).await;
    let group = fx.group.clone();
    let b = fx.members.remove(1);
    let silent = Driver::answering(RELAY, &[Answer::Silent]);
    caught_up_at(&b, &group, 0);
    silent
        .resume(&b, &DriveMode::Full, PAST_EVERY_WINDOW_MS)
        .await;
    let staged = silent.sent();
    assert_eq!(
        staged.len(),
        1,
        "premise: the self-update was sent once and not acknowledged"
    );
    assert_eq!(post_join_phases(&b, &group).await, vec!["catch_up"]);

    let b = b.reopen();
    let acking = Driver::accepting();
    acking
        .resume(&b, &DriveMode::Full, PAST_EVERY_WINDOW_MS + MINUTE_MS)
        .await;
    let resent = acking.sent();
    assert_eq!(
        resent.iter().map(|event| event.id).collect::<Vec<_>>(),
        vec![staged[0].id],
        "the restored record sends the same bytes, and nothing else"
    );
    assert_eq!(resent[0].as_json(), staged[0].as_json());
    assert_eq!(post_join_phases(&b, &group).await, vec!["complete"]);
    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        1,
        "exactly one self-update evolution exists"
    );

    // (b)
    let mut fx = setup_circle(2, &[RELAY]).await;
    let group = fx.group.clone();
    let b = fx.members.remove(1);
    let unreachable = Driver::answering(RELAY, &[Answer::Unreachable]);
    let repair_at = repair_clock_offset();
    b.session().set_legacy_clock_for_test(T0 + repair_at);
    unreachable.clock.set(repair_at);
    let repaired = through(
        &unreachable.transport,
        &unreachable.publisher,
        &unreachable.clock,
        &DriveMode::Full,
    )
    .repair_rotation(&b.circle, &group)
    .await
    .expect("the repair");
    assert!(
        matches!(
            repaired,
            haven_core::relay::fanout::RepairOutcome::Rotated(_)
        ),
        "premise: B's repair is staged and no relay could be reached"
    );
    let repair: Vec<_> = unreachable.sent().iter().map(|event| event.id).collect();
    assert_eq!(repair.len(), 1, "premise: the repair was tried once");
    caught_up_at(&b, &group, repair_at);
    unreachable
        .resume(&b, &DriveMode::Full, repair_at + PAST_EVERY_WINDOW_MS)
        .await;
    assert_eq!(
        unreachable
            .sent()
            .iter()
            .map(|event| event.id)
            .collect::<Vec<_>>(),
        repair,
        "no self-update was staged beside B's own commit"
    );
    assert_eq!(post_join_phases(&b, &group).await, vec!["catch_up"]);

    let b = b.reopen();
    assert_eq!(post_join_phases(&b, &group).await, vec!["catch_up"]);
    // The repair is refused for good; the self-update waits out the wait
    // that refusal earned, then is acknowledged.
    let after = Driver::answering(RELAY, &[Answer::Refused, Answer::Accepted]);
    let restart = repair_at + 2 * PAST_EVERY_WINDOW_MS;
    caught_up_at(&b, &group, restart);
    let refused = after
        .resume_outcome(&b, &DriveMode::Full, restart + PAST_EVERY_WINDOW_MS)
        .await;
    assert_eq!(
        after.sent().len(),
        1,
        "the repair's refusal, and nothing else"
    );
    let wait = refused
        .retry_after_ms
        .expect("the resume asks to come back when the refusal's wait ends");
    assert!(wait > 0 && wait <= RESTAGE_BASE_MS);
    after
        .resume(&b, &DriveMode::Full, restart + PAST_EVERY_WINDOW_MS + wait)
        .await;
    assert_eq!(after.sent().len(), 2, "then the self-update");
    assert_eq!(post_join_phases(&b, &group).await, vec!["complete"]);
    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        1,
        "the refused repair's evolution went with its rollback"
    );
}

/// A post-join self-update every relay proves it refuses — `invalid:`, as
/// for a device whose clock is wrong — is made again only after the wait its
/// rollback earned, doubling from a minute, however often the live
/// foreground and the poll drive; each resume inside a wait asks to come
/// back when it ends. Once the relay takes one, the obligation completes and
/// nothing more is made.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_post_join_self_update_is_made_again_only_after_a_doubling_wait() {
    let fx = setup_circle(2, &[RELAY]).await;
    let b = joiner(&fx);
    let driver = Driver::answering(RELAY, &[Answer::Invalid]);
    let live = driver.processor(b);
    assert!(
        live.for_test().prove_foreground(),
        "premise: B's live plane is in the foreground"
    );
    caught_up_at(b, &fx.group, 0);

    // A full drive every five seconds for an hour, the poll's and the live
    // plane's in turn.
    let mut made_at: Vec<u64> = Vec::new();
    let mut asked_back: Vec<(u64, Option<u64>)> = Vec::new();
    let mut at = PAST_EVERY_WINDOW_MS;
    while at <= PAST_EVERY_WINDOW_MS + HOUR_MS {
        if (at / (5 * SECOND_MS)).is_multiple_of(2) {
            let outcome = driver.resume_outcome(b, &DriveMode::Full, at).await;
            asked_back.push((at, outcome.retry_after_ms));
        } else {
            b.session().set_legacy_clock_for_test(T0 + at);
            driver.clock.set(at);
            live.for_test().drive_due().await;
        }
        if driver.sent().len() > made_at.len() {
            made_at.push(at);
        }
        at += 5 * SECOND_MS;
    }
    assert!(
        (2..=7).contains(&made_at.len()),
        "an hour of refusals made {} self-updates, not a bounded doubling few",
        made_at.len()
    );
    for (k, pair) in made_at.windows(2).enumerate() {
        assert!(
            pair[1] - pair[0] >= RESTAGE_BASE_MS << k,
            "self-update {} came before the doubling wait its refusal earned",
            k + 2
        );
    }
    let last = *made_at.last().expect("made");
    for &(asked_at, retry) in &asked_back {
        if asked_at > made_at[0] && asked_at < made_at[1] {
            let left = made_at[0] + RESTAGE_BASE_MS - asked_at;
            assert!(
                retry.is_some_and(|wait| wait <= left),
                "a resume inside the wait did not ask to come back when it ends"
            );
        }
    }

    driver.transport.answer(RELAY, [Answer::Accepted]);
    // Past the longest wait there is.
    let at = last + HOUR_MS;
    driver.resume(b, &DriveMode::Full, at).await;
    assert_eq!(
        driver.sent().len(),
        made_at.len() + 1,
        "the relay that takes it again is sent one"
    );
    assert_eq!(post_join_phases(b, &fx.group).await, vec!["complete"]);
    for tick in 1..=10 {
        driver
            .resume(b, &DriveMode::Full, at + tick * 10 * MINUTE_MS)
            .await;
        live.for_test().drive_due().await;
    }
    assert_eq!(
        driver.sent().len(),
        made_at.len() + 1,
        "nothing more is made once it is acknowledged"
    );
}

/// While a refused post-join self-update waits out its rollback's wait, the
/// circle's recovery read says nothing holds it: no eviction is owed, so it
/// is not a departure due, and its sends are not held.
#[tokio::test]
async fn a_refused_self_updates_wait_is_not_read_as_a_departure_due() {
    let fx = setup_circle(2, &[RELAY]).await;
    let b = joiner(&fx);
    let driver = Driver::answering(RELAY, &[Answer::Invalid]);
    caught_up_at(b, &fx.group, 0);
    let refused = driver
        .resume_outcome(b, &DriveMode::Full, PAST_EVERY_WINDOW_MS)
        .await;
    assert!(
        driver.sent().len() == 1 && refused.retry_after_ms.is_some(),
        "premise: the self-update was refused and its wait runs"
    );
    let at = PAST_EVERY_WINDOW_MS + SECOND_MS;
    b.session().set_legacy_clock_for_test(T0 + at);
    driver.clock.set(at);
    for mode in [DriveMode::Full, DriveMode::FinishOnly] {
        assert_eq!(
            through(&driver.transport, &driver.publisher, &driver.clock, &mode)
                .circle_recovery(&b.circle, &fx.group)
                .await
                .expect("the recovery read"),
            None,
            "a refused self-update's wait was read as holding the circle"
        );
    }
}

/// Over 48 simulated hours, a finish-only resume, a background burst's drive
/// and a background catch-up make no self-update for a caught-up joiner
/// whose windows have long passed. The first full resume does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_post_join_self_update_is_never_made_outside_a_full_drive() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = nostr_relay_builder::MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let fx = setup_circle(2, &[url.as_str()]).await;
    let b = joiner(&fx);
    let driver = Driver::answering(&url, &[Answer::Accepted]);
    let relays = haven_core::relay::RelayManager::new();
    let burst = driver.processor(b);
    burst.for_test().set_background_burst(true);
    caught_up_at(b, &fx.group, 0);
    for hour in 1..=48 {
        let at = hour * 60 * MINUTE_MS;
        driver.resume(b, &DriveMode::FinishOnly, at).await;
        burst.for_test().drive_due().await;
        if hour % 6 == 0 {
            let _ =
                haven_core::relay::catchup::run_catchup_all_circles(&b.circle, &relays, 20).await;
            caught_up_at(b, &fx.group, at);
        }
    }
    assert!(
        driver.sent().is_empty(),
        "no plane that only finishes made a self-update"
    );
    assert_eq!(
        b.session().self_update_asks_for_test(),
        0,
        "none even asked the engine"
    );
    assert_eq!(post_join_phases(b, &fx.group).await, vec!["catch_up"]);

    driver
        .resume(b, &DriveMode::Full, 49 * 60 * MINUTE_MS)
        .await;
    assert_eq!(driver.sent().len(), 1, "the first full resume makes it");
}

/// Not before the 15 s grace after the end of stored events, the 60 s quiet
/// window after it — restarted by an epoch change — and the obligation's own
/// jitter; the resume's `retry_after_ms` names the instant it may be made,
/// and it is made exactly then. Nothing arms a timer for it.
#[tokio::test]
async fn a_post_join_self_update_waits_out_grace_quiet_and_jitter_without_a_timer() {
    let fx = setup_circle(3, &[RELAY]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let driver = Driver::accepting();
    caught_up_at(b, &fx.group, 0);
    let early = driver
        .resume_outcome(b, &DriveMode::Full, 74 * SECOND_MS)
        .await;
    assert!(
        driver.sent().is_empty(),
        "nothing before grace and quiet have both passed"
    );
    let wait = early
        .retry_after_ms
        .expect("the resume names when to come back");
    let jitter = b
        .session()
        .post_join_jitter_for_test(&fx.group)
        .await
        .expect("the obligation's jitter");
    assert_eq!(
        wait,
        SECOND_MS + jitter.min(30 * SECOND_MS),
        "grace and quiet end at 75 s, then MDK's own jitter, capped at 30 s"
    );

    // An epoch change at 50 s restarts the quiet window.
    let removal = admin
        .circle
        .remove_members_for_test(&fx.group, &[fx.members[2].pubkey_hex()])
        .await
        .expect("the admin removes the third member");
    b.session().set_legacy_clock_for_test(T0 + 50 * SECOND_MS);
    b.circle.ingest_for_test(&removal).await.expect("ingest");
    let not_before = 74 * SECOND_MS + wait;
    let quieted = driver.resume_outcome(b, &DriveMode::Full, not_before).await;
    assert!(
        driver.sent().is_empty(),
        "the epoch change restarted the quiet window"
    );
    let moved = not_before + quieted.retry_after_ms.expect("the new instant is named");
    assert!(
        moved >= 50 * SECOND_MS + MINUTE_MS,
        "not within 60 s of the epoch change"
    );
    driver.resume(b, &DriveMode::Full, moved - 1).await;
    assert!(driver.sent().is_empty(), "not a millisecond early");
    driver.resume(b, &DriveMode::Full, moved).await;
    assert_eq!(
        driver.sent().len(),
        1,
        "made exactly at the instant the resume named"
    );

    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/nostr/mls/manager.rs"),
    )
    .expect("the session manager's source");
    for function in [
        "fn post_join_due(",
        "fn settle_post_join(",
        "fn post_join_may_stage(",
    ] {
        let from = source.find(function).expect("the function exists");
        let body = &source[from..from + source[from..].find("\n    }\n").expect("its end")];
        for armed in ["tokio::time", "spawn", "interval", "sleep"] {
            assert!(!body.contains(armed), "{function} arms {armed}");
        }
    }
}

/// A kind-445 for the circle routed by `routing` that nobody can decrypt:
/// its public `h` tag on random bytes, signed by a throwaway key — what
/// anyone who has seen the tag can mint.
fn undecryptable(routing: &[u8; 32]) -> Event {
    use rand::RngCore as _;
    let mut bytes = [0u8; 96];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    nostr::EventBuilder::new(
        nostr::Kind::Custom(445),
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes),
    )
    .tag(nostr::Tag::custom(
        nostr::TagKind::custom("h"),
        [hex::encode(routing)],
    ))
    .sign_with_keys(&nostr::Keys::generate())
    .expect("a forged envelope")
}

/// An outsider floods the circle with envelopes nobody can decrypt while
/// B's self-update is due: the engine queues each self-update B asks for
/// instead of making it, and the hold that queued it retires it, so no
/// queued self-update survives any resume and none is drained later. Once
/// the flood is spent, exactly one self-update is made.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_self_update_the_engine_queued_is_never_drained() {
    let fx = setup_circle(3, &[RELAY]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let routing = helpers::drive::ngid(b, &fx.group).await;
    // MDK's whole per-circle deferral store, so the advance that applies the
    // commit below leaves rows untried.
    loop {
        let ScreenedIngest::Ingested(ingest) = b
            .session()
            .process_event(&undecryptable(&routing))
            .await
            .expect("an undecryptable envelope is not an ingest failure")
        else {
            panic!("a well-formed envelope passes the pre-auth screen");
        };
        match ingest.outcome {
            IngestOutcome::TransportDeferred { .. } => {}
            IngestOutcome::ResourceRefused { .. } => break,
            _ => panic!("an undecryptable envelope is deferred or refused"),
        }
    }
    // A commit re-arms every deferred row: the engine tries each again at the
    // new epoch, four a send.
    let removal = admin
        .circle
        .remove_members_for_test(&fx.group, &[fx.members[2].pubkey_hex()])
        .await
        .expect("the admin removes the third member");
    b.session().set_legacy_clock_for_test(T0);
    let session = b.session();
    let before = epoch(b, &fx.group).await;
    session.process_event(&removal).await.expect("ingest");
    // Applied through single user-facing advances, which drain nothing,
    // each waiting out the deadline the engine announces.
    for _ in 0..40 {
        if epoch(b, &fx.group).await > before {
            break;
        }
        if let Some(after) = session.receive_retick_after(&fx.group).await {
            tokio::time::sleep(after).await;
        }
        session
            .advance_convergence(&fx.group)
            .await
            .expect("advance");
    }
    assert!(
        epoch(b, &fx.group).await > before,
        "premise: the removal applied"
    );
    assert!(
        b.session().deferred_peels_untried_for_test(&fx.group).await,
        "premise: the flood is re-armed and untried"
    );
    let driver = Driver::accepting();
    caught_up_at(b, &fx.group, 0);
    let mut queued_seen = false;
    for tick in 1..=3 {
        let asks = b.session().self_update_asks_for_test();
        driver
            .resume(b, &DriveMode::Full, tick * PAST_EVERY_WINDOW_MS)
            .await;
        let asked = b.session().self_update_asks_for_test() > asks;
        assert_eq!(
            b.session()
                .queued_self_update_count_for_test(&fx.group)
                .await
                .expect("read the queue"),
            0,
            "resume {tick} left a queued self-update for a later drain"
        );
        assert!(
            driver.sent().is_empty(),
            "nothing is made while the flood is untried"
        );
        queued_seen |= asked;
    }
    assert!(
        queued_seen,
        "premise: a self-update was asked for and queued by the engine"
    );
    // The flood is spent: each row has had its try.
    for _ in 0..400 {
        if !b.session().deferred_peels_untried_for_test(&fx.group).await {
            break;
        }
        b.session()
            .advance_convergence(&fx.group)
            .await
            .expect("advance");
    }
    assert!(!b.session().deferred_peels_untried_for_test(&fx.group).await);
    driver
        .resume(b, &DriveMode::Full, 4 * PAST_EVERY_WINDOW_MS)
        .await;
    assert_eq!(driver.sent().len(), 1, "exactly one self-update was made");
    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        1,
        "exactly one self-update evolution"
    );
    for tick in 13..=16 {
        driver
            .resume(b, &DriveMode::Full, tick * PAST_EVERY_WINDOW_MS)
            .await;
    }
    assert_eq!(
        driver.sent().len(),
        1,
        "nothing queued was drained afterwards"
    );
}

/// A device in two circles owes two post-join self-updates: one resume makes
/// one, and the other waits at least a CSPRNG gap of 2 s more on the clock
/// that makes them, so their commits never share a second
/// (`INV-R-PER-CIRCLE-PUBLISH-DECORRELATED`).
#[tokio::test]
async fn the_upgrade_burst_makes_one_self_update_a_resume_and_spaces_the_next() {
    let founder = CircleMember::new();
    let b = CircleMember::new();
    let first = helpers::found_circle(&founder, &[&b], &[RELAY]).await;
    let second = helpers::found_circle(&founder, &[&b], &[RELAY]).await;
    let driver = Driver::accepting();
    caught_up_at(&b, &first, 0);
    caught_up_at(&b, &second, 0);
    let due = PAST_EVERY_WINDOW_MS;
    let made = driver.resume_outcome(&b, &DriveMode::Full, due).await;
    assert_eq!(driver.sent().len(), 1, "one self-update per resume");
    let spaced = made
        .retry_after_ms
        .expect("the next circle's instant is named");
    assert!(
        (2 * SECOND_MS..=30 * SECOND_MS).contains(&spaced),
        "the gap is the stagger's, at least 2 s"
    );
    driver.resume(&b, &DriveMode::Full, due + spaced - 1).await;
    assert_eq!(driver.sent().len(), 1, "not a millisecond inside the gap");
    driver.resume(&b, &DriveMode::Full, due + spaced).await;
    assert_eq!(driver.sent().len(), 2, "the second circle's, after the gap");
    for group in [&first, &second] {
        assert_eq!(post_join_phases(&b, group).await, vec!["complete"]);
    }
}

/// How often the 30-day test ticks, in simulated hours. Every wake kind
/// still runs every simulated day.
const TICK_HOURS: u64 = 4;

/// A-3 (V2-22): no wake and no amount of elapsed time ever authors a
/// self-update. Founder A and joiner B, 30 simulated days. B's one post-join
/// self-update is made at day 0; from then on, through peer fixes taken in
/// by poll and by the live plane, full and finish-only resumes, the live
/// plane's drive, a foreground catch-up sweep every six hours, a
/// `KeyPackage` maintenance daily and a flood of envelopes nobody can
/// decrypt, B's self-update evolutions, its epoch and the kind-445 commits
/// any transport was handed stay exactly as they were, no obligation but the
/// joiner's post-join ever exists, and no circle is enrolled in periodic
/// rotation. A user's repair at day 30, with its gates open, adds exactly
/// one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn no_wake_or_elapsed_time_ever_authors_a_self_update() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = nostr_relay_builder::MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let fx = setup_circle(2, &[url.as_str()]).await;
    let (admin, b) = (fx.admin(), joiner(&fx));
    let routing = helpers::drive::ngid(b, &fx.group).await;
    let driver = Driver::answering(&url, &[Answer::Accepted]);
    let relays = haven_core::relay::RelayManager::new();
    let live = driver.processor(b);
    assert!(
        live.for_test().prove_foreground(),
        "premise: B's live plane is in the foreground"
    );
    let admin_live = Driver::answering(&url, &[Answer::Accepted]);
    let admin_plane = admin_live.processor(admin);

    let post_join = settle_post_join(&driver, b, &fx.group, 0).await;
    admin
        .circle
        .ingest_for_test(&post_join)
        .await
        .expect("ingest");
    let evolutions = b
        .session()
        .group_evolution_count_for_test()
        .await
        .expect("read");
    let settled_epoch = epoch(b, &fx.group).await;
    let commits = driver.sent().len();
    assert_eq!(
        (evolutions, commits),
        (1, 1),
        "premise: the one post-join self-update"
    );

    let started = std::time::Instant::now();
    let mut kp_slot: Option<String> = None;
    for tick in 1..=(30 * 24 / TICK_HOURS) {
        let hour = tick * TICK_HOURS;
        let at = hour * 60 * MINUTE_MS + PAST_EVERY_WINDOW_MS;
        admin.session().set_legacy_clock_for_test(T0 + at);
        b.session().set_legacy_clock_for_test(T0 + at);
        let latitude = f64::from(u32::try_from(tick).expect("ticks")) * 0.001;
        // A peer's fix by poll, B's by A's live plane.
        let (from_admin, _, _) = admin
            .circle
            .seal_location_for_test(&fx.group, &LocationMessage::new(latitude, 1.0))
            .await
            .expect("the admin seals");
        b.circle
            .ingest_for_test(&from_admin)
            .await
            .expect("B takes it in");
        let (from_b, _, _) = b
            .circle
            .seal_location_for_test(&fx.group, &LocationMessage::new(latitude, 2.0))
            .await
            .expect("B seals");
        admin_plane.process_group_event(&from_b, &routing).await;
        // Every wake kind.
        driver.resume(b, &DriveMode::Full, at).await;
        driver.resume(b, &DriveMode::FinishOnly, at).await;
        live.for_test().drive_due().await;
        // Every six hours: each tick that crosses a six-hour mark.
        if hour / 6 != (hour - TICK_HOURS) / 6 {
            let _ =
                haven_core::relay::catchup::run_catchup_in_foreground(&b.circle, &relays, 20).await;
        }
        if hour.is_multiple_of(24) {
            let package = haven_core::relay::maintenance::build_kp_maintenance_events(
                b.session(),
                &b.keys,
                std::slice::from_ref(&url),
                kp_slot.as_deref(),
                None,
            )
            .await
            .expect("the daily KeyPackage maintenance");
            kp_slot = Some(package.d_tag);
        }
        // Day 10: an outsider's flood.
        if hour / 24 == 10 && hour % 24 < TICK_HOURS {
            for _ in 0..64 {
                let _ = b.session().process_event(&undecryptable(&routing)).await;
            }
        }
    }
    eprintln!("30-day walk: {:?}", started.elapsed());

    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        evolutions,
        "a wake or elapsed time made a self-update"
    );
    assert_eq!(
        epoch(b, &fx.group).await,
        settled_epoch,
        "the epoch never moved"
    );
    assert_eq!(
        driver.sent().len(),
        commits,
        "no commit was handed to B's transport"
    );
    assert!(
        admin_live.sent().is_empty(),
        "no commit was handed to the admin's live plane"
    );
    assert_eq!(
        b.session().obligations_for_test(&fx.group).await,
        vec![("post_join", "complete")],
        "no obligation but the joiner's post-join ever existed"
    );
    for member in [admin, b] {
        assert!(
            !member
                .session()
                .periodic_rotation_enrolled_for_test(&fx.group)
                .await
                .expect("read"),
            "a circle was enrolled in periodic rotation"
        );
    }

    // Non-vacuity: the user's repair, gates open, adds exactly one.
    let repair_at = repair_clock_offset();
    driver.clock.set(repair_at);
    let repaired = through(
        &driver.transport,
        &driver.publisher,
        &driver.clock,
        &DriveMode::Full,
    )
    .repair_rotation(&b.circle, &fx.group)
    .await
    .expect("the repair");
    assert!(matches!(
        repaired,
        haven_core::relay::fanout::RepairOutcome::Rotated(_)
    ));
    assert_eq!(
        b.session()
            .group_evolution_count_for_test()
            .await
            .expect("read"),
        evolutions + 1
    );
    assert_eq!(driver.sent().len(), commits + 1);
}
