//! Send-side changes made through one Rust call each (Security Rule 13).
//!
//! Remove, relay update, admin handoff, self-demote, repair and add are each
//! staged under a durable fanout in the hold that stages them, driven, and
//! answered with a typed outcome: applied, awaiting relays, undone, or queued
//! — never "failed" for a change no relay has answered for yet. An invite's
//! Welcome goes out only once its commit is applied and still canonical, to
//! its invitee's own relays, and is completed only on a relay's
//! acknowledgement of that exact event. And a session's first resume drives
//! whatever an earlier process left.
//!
//! Real MDK engines over `SQLCipher` stores. The fanout transport is scripted
//! and the publisher of everything else records what it is handed: nothing is
//! dialled. Every instant is read from a clock the test sets; the only real
//! time paid is the engine's own announced deadline where a received commit
//! or proposal has to be applied (`docs/MDK_UPSTREAM_TRACKER.md`
//! T-CONVERGENCE-CLOCK).

mod helpers;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use haven_core::circle::{CircleManager, MemberKeyPackage, SkipReason};
use haven_core::nostr::mls::storage::{
    set_engine_write_fault_for_test, set_epoch_anchor_write_fault_for_test,
    set_stored_message_write_fault_for_test, EngineWrite,
};
use haven_core::nostr::mls::types::{
    EpochState, FanoutId, FanoutMls, FanoutProbe, FanoutTargetStatus, GroupId,
    LocationMessageResult, MessageId, MessageState, OpenMlsContentKind, PendingStateRef,
    PublishWork,
};
use haven_core::nostr::mls::{ChangeNote, SessionManager, StorageConfig, StoreFault};
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::fanout::{
    drive_one, wake_deadline, DriveMode, EvolutionStatus, FanoutClock, FanoutStatus, ModeSource,
    Publishing, RepairOutcome, WallClock, BUSY_RETRY_MS, RESUME_BUDGET_MS, ROW_BUDGET_MS,
};
use haven_core::relay::scripted_relay::ScriptedRelay;
use haven_core::relay::RelayManager;
use helpers::{
    assert_no_needles, capture_haven_log, create_key_package_event, setup_circle, BalkyNotes,
    CircleFixture, CircleMember, LogLine,
};

const ONE: &str = "wss://one.change-canary3d8f.example.com";
const TWO: &str = "wss://two.change-canary3d8f.example.com";
const THREE: &str = "wss://three.change-canary3d8f.example.com";
const INBOX: &str = "wss://inbox.change-canary3d8f.example.com";
const CANARY: &str = "change-canary3d8f";

const SECOND_MS: u64 = 1_000;
const HOUR_MS: u64 = 3_600 * SECOND_MS;
const DAY_MS: u64 = 24 * HOUR_MS;
const STAGED_AT: u64 = 1_700_000_000_000;

/// A clock a test sets, read as an offset from a fixed instant.
struct Clock {
    origin: u64,
    offset: AtomicU64,
}

impl Clock {
    const fn at(offset_ms: u64) -> Self {
        Self {
            origin: STAGED_AT,
            offset: AtomicU64::new(offset_ms),
        }
    }

    /// A clock that starts `ahead_ms` after the device's own. The
    /// epoch-rotation repair's gates read stamps the device's clock wrote:
    /// three days on they are open, and at no distance they are shut.
    fn ahead_of_the_device(ahead_ms: u64) -> Self {
        let now = u64::try_from(chrono::Utc::now().timestamp_millis()).expect("after 1970");
        Self {
            origin: now + ahead_ms,
            offset: AtomicU64::new(0),
        }
    }

    fn set(&self, offset_ms: u64) {
        self.offset.store(offset_ms, Ordering::SeqCst);
    }
}

impl FanoutClock for Clock {
    fn now_ms(&self) -> u64 {
        self.origin + self.offset.load(Ordering::SeqCst)
    }
}

/// Where everything that has no fanout record is handed: a commit an advance
/// staged the legacy way, a bare proposal, a Welcome. It records each and
/// acknowledges it, unless told to withhold.
#[derive(Default)]
struct Outbox {
    handed: Mutex<Vec<(nostr::Event, Vec<String>)>>,
    /// Recipients whose Welcome no relay acknowledges.
    unacknowledged: Mutex<Vec<String>>,
    /// Whose roster to read as each Welcome is handed over, and for whom.
    watched: Mutex<Option<(Arc<CircleManager>, GroupId, String)>>,
    sent_early: AtomicBool,
    /// Whose commit, staged at which epoch of which circle, to restate as
    /// set aside when the first event is handed over.
    sets_aside: Mutex<Option<(Arc<CircleManager>, GroupId, u64)>>,
    /// Whose Welcome record to delete while its Welcome is handed over: what
    /// another drive's end of it does.
    ends_record: Mutex<Option<(Arc<CircleManager>, MessageId)>>,
    /// Whose message store to make refuse writes while a Welcome is handed
    /// over: what keeps its delivery from being marked.
    refuses_marks: Mutex<Option<(std::path::PathBuf, storage_sqlite::SqlCipherKey)>>,
    /// Whose drive to run, beside the call, while the first event is handed
    /// over: what the live plane's own drive does when it runs then.
    drives_beside: Mutex<Option<Arc<CircleManager>>>,
}

impl Outbox {
    /// Has every Welcome handed over checked against `member`'s own roster:
    /// one handed over while `invitee` is not on it left too early.
    fn watch(&self, member: &CircleMember, group: &GroupId, invitee: &CircleMember) {
        *self.watched.lock().expect("outbox") = Some((
            Arc::clone(&member.circle),
            group.clone(),
            invitee.pubkey_hex(),
        ));
    }

    fn sent_a_welcome_early(&self) -> bool {
        self.sent_early.load(Ordering::SeqCst)
    }

    /// Has the first event handed over restate the commit `member` staged at
    /// `epoch` as provisionally set aside, before the hand-over is answered:
    /// what a convergence pass that ran between two sends would leave.
    fn set_aside_on_first_hand(&self, member: &CircleMember, group: &GroupId, epoch: u64) {
        *self.sets_aside.lock().expect("outbox") =
            Some((Arc::clone(&member.circle), group.clone(), epoch));
    }

    fn withhold_welcome_to(&self, recipient_hex: &str) {
        self.unacknowledged
            .lock()
            .expect("outbox")
            .push(recipient_hex.to_owned());
    }

    fn acknowledge_everything(&self) {
        self.unacknowledged.lock().expect("outbox").clear();
    }

    fn handed(&self) -> Vec<(nostr::Event, Vec<String>)> {
        std::mem::take(&mut self.handed.lock().expect("outbox"))
    }
}

/// The identity a gift wrap is addressed to.
fn recipient_of(event: &nostr::Event) -> Option<String> {
    event.tags.iter().find_map(|tag| {
        let tag = tag.as_slice();
        (tag.len() >= 2 && tag[0] == "p").then(|| tag[1].clone())
    })
}

impl UnrecordedPublisher for Outbox {
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a nostr::Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            let watched = self.watched.lock().expect("outbox").clone();
            if let Some((circle, group, invitee)) = watched.filter(|_| event.kind.as_u16() == 1059)
            {
                let roster = circle.session().member_pubkeys(&group).await;
                if !roster.is_ok_and(|roster| roster.contains(&invitee)) {
                    self.sent_early.store(true, Ordering::SeqCst);
                }
            }
            self.handed
                .lock()
                .expect("outbox")
                .push((event.clone(), relays.to_vec()));
            let beside = self.drives_beside.lock().expect("outbox").take();
            if let Some(circle) = beside {
                let _ = through(&ScriptedFanout::default(), &Self::default(), &Clock::at(0))
                    .resume(&circle)
                    .await;
            }
            let ends = self.ends_record.lock().expect("outbox").take();
            if let Some((circle, welcome)) = ends {
                circle
                    .session()
                    .delete_welcome_record_for_test(&welcome)
                    .await;
            }
            let refuses = self.refuses_marks.lock().expect("outbox").take();
            if let Some((db, key)) = refuses {
                set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
            }
            let sets_aside = self.sets_aside.lock().expect("outbox").take();
            if let Some((circle, group, epoch)) = sets_aside {
                let commit = circle
                    .session()
                    .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, epoch)
                    .await
                    .expect("the commit's own row");
                circle
                    .session()
                    .stage_convergence_input_for_test(&commit, MessageState::ConvergenceDeferred, 0)
                    .await
                    .expect("the commit is restated");
            }
            let withheld = self.unacknowledged.lock().expect("outbox");
            !recipient_of(event).is_some_and(|recipient| withheld.contains(&recipient))
        })
    }
}

fn welcomes(handed: &[(nostr::Event, Vec<String>)]) -> Vec<&(nostr::Event, Vec<String>)> {
    handed
        .iter()
        .filter(|(event, _)| event.kind.as_u16() == 1059)
        .collect()
}

fn answering(answers: &[(&str, &[Answer])]) -> ScriptedFanout {
    let transport = ScriptedFanout::default();
    for (target, script) in answers {
        transport.answer(target, script.iter().copied());
    }
    transport
}

const fn through<'a>(
    fanout: &'a ScriptedFanout,
    publisher: &'a Outbox,
    clock: &'a Clock,
) -> Publishing<'a, ScriptedFanout> {
    Publishing {
        fanout,
        publisher,
        clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    }
}

fn split(fx: CircleFixture) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let mut members = fx.members;
    let admin = members.remove(0);
    (admin, members, fx.group)
}

async fn rows_of(member: &CircleMember, group: &GroupId) -> Vec<FanoutId> {
    member
        .session()
        .fanout_ids_for_test(group)
        .await
        .expect("the store is read")
}

async fn probe(member: &CircleMember, id: &FanoutId) -> Option<FanoutProbe> {
    member
        .session()
        .fanout_probe_for_test(id)
        .await
        .expect("the store is read")
}

async fn the_row(member: &CircleMember, group: &GroupId) -> (FanoutId, FanoutProbe) {
    let [id] = <[FanoutId; 1]>::try_from(rows_of(member, group).await)
        .unwrap_or_else(|_| panic!("exactly one fanout row"));
    let row = probe(member, &id).await.expect("the row exists");
    (id, row)
}

async fn staged_ref(member: &CircleMember, group: &GroupId) -> Option<PendingStateRef> {
    match member.session().epoch_state(group).await {
        Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
        _ => None,
    }
}

async fn commit_state(member: &CircleMember, event: nostr::EventId) -> Option<MessageState> {
    member
        .session()
        .stored_message_record_for_test(&MessageId::new(event.to_bytes().to_vec()))
        .await
        .expect("the store is read")
        .map(|record| record.state)
}

async fn roster(member: &CircleMember, group: &GroupId) -> Vec<String> {
    member
        .session()
        .member_pubkeys(group)
        .await
        .expect("the roster")
}

async fn seal(sender: &CircleMember, group: &GroupId) -> Option<nostr::Event> {
    sender
        .circle
        .seal_location_for_test(
            group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await
        .ok()
        .map(|sealed| sealed.0)
}

async fn can_send(member: &CircleMember, group: &GroupId) -> bool {
    seal(member, group).await.is_some()
}

/// Whether `reader` reads the location `event` carries.
async fn opens(reader: &CircleMember, event: &nostr::Event) -> bool {
    reader
        .circle
        .ingest_for_test(event)
        .await
        .is_ok_and(|results| {
            results
                .iter()
                .any(|result| matches!(result, LocationMessageResult::Location { .. }))
        })
}

fn directory(member: &CircleMember) -> Vec<String> {
    member
        .circle
        .ranked_directory_members(chrono::Utc::now().timestamp())
        .expect("the directory")
        .into_iter()
        .map(|entry| entry.pubkey_hex)
        .collect()
}

async fn nostr_group_id(member: &CircleMember, group: &GroupId) -> [u8; 32] {
    member
        .session()
        .group_routing(group)
        .await
        .expect("routing")
        .0
}

fn line_saying<'a>(lines: &'a [LogLine], words: &str) -> &'a LogLine {
    lines
        .iter()
        .find(|line| line.message.contains(words))
        .unwrap_or_else(|| panic!("no log line says: {words}"))
}

fn db_of(member: &CircleMember) -> (std::path::PathBuf, storage_sqlite::SqlCipherKey) {
    (
        StorageConfig::new(member.dir.path()).database_path(),
        StorageConfig::test_sqlcipher_key().expect("test key"),
    )
}

/// Gives the stored message `id` names the state `state`, in a closed store.
fn restate(member: CircleMember, id: &[u8], state: MessageState) -> CircleMember {
    use cgka_traits::storage::MessageStorage;

    let (db, key) = db_of(&member);
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    haven_core::sqlcipher_init::ensure().expect("sqlite");
    let store = storage_sqlite::SqliteAccountStorage::open_encrypted_with_options(
        &db,
        &key,
        StorageConfig::storage_options(),
    )
    .expect("the closed store opens");
    store
        .update_message_state(&MessageId::new(id.to_vec()), state)
        .expect("the stored message is restated");
    drop(store);
    CircleMember {
        circle: std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ),
        keys,
        dir,
    }
}

/// The closed MLS store of `member`, who is given back reopened once `edit`
/// has run on it.
fn with_closed_store(
    member: CircleMember,
    edit: impl FnOnce(&storage_sqlite::SqliteAccountStorage),
) -> CircleMember {
    let (db, key) = db_of(&member);
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    haven_core::sqlcipher_init::ensure().expect("sqlite");
    let store = storage_sqlite::SqliteAccountStorage::open_encrypted_with_options(
        &db,
        &key,
        StorageConfig::storage_options(),
    )
    .expect("the closed store opens");
    edit(&store);
    drop(store);
    CircleMember {
        circle: std::sync::Arc::new(
            CircleManager::new_unencrypted(dir.path(), &keys).expect("the stores reopen"),
        ),
        keys,
        dir,
    }
}

/// Someone to invite: a member of nothing yet, and what an inviter holds of
/// them.
async fn an_invitee() -> (CircleMember, MemberKeyPackage) {
    let invitee = CircleMember::new();
    let inbox = vec![INBOX.to_string()];
    let key_package_event =
        create_key_package_event(invitee.session(), &invitee.keys, &inbox).await;
    (
        invitee,
        MemberKeyPackage {
            key_package_event,
            inbox_relays: inbox,
            nip65_relays: Vec::new(),
        },
    )
}

// ── Remove ───────────────────────────────────────────────────────────────────

/// A removal a relay acknowledges is applied in the call that made it, and
/// the removed member leaves the roster and the directory.
#[tokio::test]
async fn a_removal_is_applied_in_its_own_call_on_a_relays_acknowledgement() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    admin
        .circle
        .reconcile_member_directory(
            haven_core::circle::DirectoryReconcile::Rewrite,
            chrono::Utc::now().timestamp(),
        )
        .await
        .expect("the directory is written");
    assert!(directory(&admin).contains(&removed), "premise");
    let before = seal(&admin, &group).await.expect("the admin seals");
    assert!(
        opens(&others[1], &before).await,
        "premise: the member about to be removed reads the circle",
    );
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
        .await
        .expect("the removal is accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (0, 0));
    assert!(outcome.notes.is_empty());
    assert_eq!(
        outcome.retry_after_ms, None,
        "a change both its relays hold asked to be driven again",
    );
    assert!(!roster(&admin, &group).await.contains(&removed));
    assert!(
        staged_ref(&admin, &group).await.is_none() && can_send(&admin, &group).await,
        "the circle is not usable after an applied removal",
    );
    assert!(
        !directory(&admin).contains(&removed),
        "a removed member is still offered by the directory",
    );
    let sent = transport.calls();
    assert_eq!(sent.len(), 2, "one call per relay, and no more");
    assert!(
        outbox.handed().is_empty(),
        "a recorded commit left the device by another way than its fanout",
    );
    assert!(rows_of(&admin, &group).await.is_empty());

    // It removes: what is sealed afterwards the remaining member reads and
    // the removed member does not.
    let commit =
        <nostr::Event as nostr::JsonUtil>::from_json(&sent[0].payload).expect("the frozen event");
    others[0]
        .session()
        .process_event_settled_for_test(&commit)
        .await
        .expect("the remaining member applies the removal");
    let after = seal(&admin, &group).await.expect("the admin seals");
    assert!(
        opens(&others[0], &after).await,
        "a remaining member cannot read what was sealed after the removal",
    );
    let _ = others[1]
        .session()
        .process_event_settled_for_test(&commit)
        .await;
    assert!(
        !opens(&others[1], &after).await,
        "a removed member reads what was sealed after their removal",
    );
}

/// A change no relay has answered for is AWAITING RELAYS, however the call
/// ended: it is not an error and not a failure. Its commit stays staged and
/// recorded, nothing is undone, and the next drive — with a relay back —
/// applies the very event that was staged.
#[tokio::test]
async fn a_change_no_relay_answers_for_is_awaiting_relays_never_failed() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Unreachable])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
        .await
        .unwrap_or_else(|_| panic!("a change awaiting its relays was reported as an error"));

    assert_eq!(
        outcome.status,
        EvolutionStatus::Unresolved,
        "a change no relay answered for was not reported as awaiting relays",
    );
    let (id, row) = the_row(&admin, &group).await;
    assert_eq!(row.mls, FanoutMls::Pending);
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && commit_state(&admin, row.event_id).await == Some(MessageState::Sent),
        "a change awaiting its relays was undone",
    );
    assert!(
        admin.session().take_change_notes(&group).is_empty(),
        "a change awaiting its relays was noted as undone",
    );
    assert!(
        outcome.retry_after_ms.is_some_and(|wait| wait > 0),
        "a change awaiting its relays did not say when to try them again",
    );
    transport.calls();

    // A later resume, a relay back: applied, with the frozen bytes.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let resumed = through(&transport, &outbox, &clock)
        .resume(&admin.circle)
        .await;
    assert!(!resumed.errored);
    assert!(transport
        .calls()
        .iter()
        .all(|call| call.event_id == row.event_id && call.payload == row.payload));
    assert!(!roster(&admin, &group).await.contains(&removed));
    assert!(staged_ref(&admin, &group).await.is_none());
    assert!(
        probe(&admin, &id)
            .await
            .is_none_or(|row| row.mls == FanoutMls::Confirmed),
        "the applied commit's record still reads pending",
    );
}

/// A change every relay proved it refused is undone, and says so — to the
/// caller, who is told in the outcome, and so not a second time by a note
/// left for later.
#[tokio::test]
async fn a_change_every_relay_refused_is_undone_and_its_caller_is_told_in_the_outcome() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
        .await
        .expect("the removal is accepted");

    assert_eq!(outcome.status, EvolutionStatus::RolledBack);
    assert!(roster(&admin, &group).await.contains(&removed));
    assert!(staged_ref(&admin, &group).await.is_none() && can_send(&admin, &group).await);
    assert!(rows_of(&admin, &group).await.is_empty());
    assert!(
        admin.session().take_change_notes(&group).is_empty(),
        "the caller was told in the outcome and a note was still left to tell it again",
    );
}

// ── Relay update, handoff, demote ────────────────────────────────────────────

/// What a circle has not been told about an EARLIER change stays untold when
/// a later change of the same kind is made and answered in its own outcome.
/// A removal every relay refused in a drive nobody waited on leaves its note;
/// a second removal, refused in the call that asked for it, is told to its
/// caller there — and the first one's note is still there to be read.
#[tokio::test]
async fn an_earlier_changes_unread_note_survives_a_later_change_of_its_circle() {
    let fx = setup_circle(3, &[ONE, TWO]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Refused]), (TWO, &[Answer::Refused])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    // Staged by one call and undone by a drive nobody is waiting on.
    let staged = admin
        .circle
        .remove_members_staging(&group, &[others[0].pubkey_hex()], clock.now_ms())
        .await
        .expect("a removal is staged");
    let id = staged.commit.expect("its own record");
    let undone = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the drive runs"));
    assert_eq!(undone.status, FanoutStatus::RolledBack);
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::RemovalUndone],
        "premise: the undone removal left its note",
    );

    clock.set(2 * HOUR_MS);
    let outcome = through(&transport, &outbox, &clock)
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("the removal is accepted");
    assert_eq!(outcome.status, EvolutionStatus::RolledBack);
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::RemovalUndone],
        "a later change that was told to its caller took an earlier change's unread note with it",
    );
}

/// A relay update is sent to the relays of the epoch it leaves, and once it
/// is applied the circle's own relay list follows the engine's, with no
/// second call from anybody.
#[tokio::test]
async fn a_relay_update_goes_to_the_relays_it_leaves_and_the_circle_row_follows_the_confirm() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .update_relays(&admin.circle, &group, &[THREE.to_string()])
        .await
        .expect("the update is accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    let mut sent_to: Vec<String> = transport.calls().into_iter().map(|c| c.target).collect();
    sent_to.sort();
    assert_eq!(
        sent_to,
        [ONE, TWO],
        "a routing change must reach the members where they are still listening",
    );
    let row = admin
        .circle
        .get_circle(&group)
        .await
        .expect("the circle is read")
        .expect("the circle exists");
    assert_eq!(
        row.circle.relays,
        [THREE],
        "the circle's relay list did not follow the applied update",
    );
}

/// A change whose row another drive holds when its own call reaches it — the
/// live plane's, say — is driven again once that drive lets go, and applied
/// in the call; a busy row asks for no wake, so it would otherwise wait for
/// the next trigger.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_whose_row_another_drive_holds_is_driven_again_when_it_lets_go() {
    use haven_core::relay::fanout::{
        a_row_is_waited_for_test, before_next_change_drive_for_test, hold_fanout_row_for_test,
    };
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    before_next_change_drive_for_test(&group, |id| {
        let hold = hold_fanout_row_for_test(id).expect("premise: nothing drives the row yet");
        tokio::spawn(async move {
            a_row_is_waited_for_test().await;
            drop(hold);
        });
    });

    let outcome = through(&transport, &outbox, &clock)
        .update_relays(&admin.circle, &group, &[THREE.to_string()])
        .await
        .expect("the update is driven");

    assert_eq!(
        outcome.status,
        EvolutionStatus::Confirmed,
        "a change whose row was busy was left for the next trigger"
    );
}

/// What a relay update's call and another drive — the live plane's, say —
/// each left when that drive took the update's row first and ended its
/// record before the call was let back in.
struct EndedBeside {
    /// What the update's call answered.
    status: EvolutionStatus,
    /// What the other drive did with the record.
    beside: FanoutStatus,
    /// The record was gone when the other drive let go of it.
    ended: bool,
    /// Relays the update's call itself sent to.
    own_calls: usize,
    /// The engine's relays for the circle afterwards include the update's.
    routed_to_new: bool,
}

/// A relay update whose row another drive holds when the update's call first
/// drives it, which every relay answers `answer` in that other drive. The
/// row is let go and taken by the other drive in one step, so the call's own
/// drive is let back in only once the record is resolved and ended; the
/// clock never moves, so the call waits on the row and on nothing else.
async fn a_relay_update_another_drive_ends(answer: Answer) -> EndedBeside {
    use haven_core::relay::fanout::{
        a_row_is_waited_for_test, before_next_change_drive_for_test, hold_fanout_row_for_test,
    };
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let own = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let other = answering(&[(ONE, &[answer]), (TWO, &[answer])]);
    let outbox = Outbox::default();
    let clock = helpers::drive::ManualClock::at(0);
    let (hand_over, handed) = tokio::sync::oneshot::channel();
    before_next_change_drive_for_test(&group, move |id| {
        let hold = hold_fanout_row_for_test(id).expect("premise: nothing drives the row yet");
        let _ = hand_over.send((id.clone(), hold));
    });
    let changes = Publishing {
        fanout: &own,
        publisher: &outbox,
        clock: &*clock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let beside = async {
        let (id, hold) = handed.await.expect("the change reaches its drive");
        a_row_is_waited_for_test().await;
        drop(hold);
        let driven = drive_one(&admin.circle, &other, &*clock, &id, &DriveMode::Full)
            .await
            .unwrap_or_else(|_| panic!("the other drive runs"));
        (driven.status, probe(&admin, &id).await.is_none())
    };
    let new_relays = [THREE.to_string()];
    let (outcome, (beside, ended)) = tokio::join!(
        changes.update_relays(&admin.circle, &group, &new_relays),
        beside,
    );
    let status = outcome
        .unwrap_or_else(|_| panic!("the update is accepted"))
        .status;
    let (_, routed) = admin
        .session()
        .group_routing(&group)
        .await
        .expect("the routing reads");
    EndedBeside {
        status,
        beside,
        ended,
        own_calls: own.calls().len(),
        routed_to_new: routed
            .iter()
            .any(|relay| relay.trim_end_matches('/') == THREE),
    }
}

/// A change another drive confirmed and ended before its own call could
/// drive it is applied, and the call says so: the record is gone, and the
/// commit's own stored row says it was applied.
#[tokio::test]
async fn a_change_another_drive_confirms_and_ends_is_answered_applied() {
    let ended = a_relay_update_another_drive_ends(Answer::Accepted).await;

    assert!(
        ended.beside == FanoutStatus::Confirmed
            && ended.ended
            && ended.own_calls == 0
            && ended.routed_to_new,
        "premise: the other drive applied the update and ended its record",
    );
    assert_eq!(
        ended.status,
        EvolutionStatus::Confirmed,
        "a change another drive applied was answered as still awaiting relays",
    );
}

/// A change another drive rolled back and ended before its own call could
/// drive it is undone, and the call says so, never "awaiting relays".
#[tokio::test]
async fn a_change_another_drive_rolls_back_and_ends_is_answered_undone() {
    let ended = a_relay_update_another_drive_ends(Answer::Refused).await;

    assert!(
        ended.beside == FanoutStatus::RolledBack
            && ended.ended
            && ended.own_calls == 0
            && !ended.routed_to_new,
        "premise: the other drive rolled the update back and ended its record",
    );
    assert_eq!(
        ended.status,
        EvolutionStatus::RolledBack,
        "a change another drive undid was answered as still awaiting relays",
    );
}

/// Saving the relay list a circle already has — in any order, in any of its
/// spellings — stages nothing: no commit, no relay called, the epoch where
/// it was.
#[tokio::test]
async fn saving_an_unchanged_relay_list_stages_nothing() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let before = admin
        .circle
        .group_epoch(&group)
        .await
        .expect("the epoch reads");
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .update_relays(
            &admin.circle,
            &group,
            &[format!("{TWO}/"), ONE.to_string(), ONE.to_string()],
        )
        .await
        .expect("the save is answered");

    assert!(
        outcome.status == EvolutionStatus::AlreadySo
            && transport.calls().is_empty()
            && admin
                .circle
                .group_epoch(&group)
                .await
                .expect("the epoch reads")
                == before,
        "saving the relay list the circle already has staged a commit",
    );
}

/// Re-saving the relays a circle has applied while this device's own change
/// of them is still pending is not "already so": the pending change is not
/// undone by saying so, and an acknowledgement would move the circle to the
/// relays the user just turned away from. The save goes to the engine, as
/// any change made while another is pending does.
#[tokio::test]
async fn re_saving_the_applied_relays_while_a_change_is_pending_is_not_already_so() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let widened = changes
        .update_relays(
            &admin.circle,
            &group,
            &[ONE.to_string(), TWO.to_string(), THREE.to_string()],
        )
        .await
        .expect("the save is answered");
    assert_eq!(
        widened.status,
        EvolutionStatus::Unresolved,
        "premise: the change is pending on its relays"
    );

    let back = changes
        .update_relays(&admin.circle, &group, &[ONE.to_string(), TWO.to_string()])
        .await;
    assert!(
        !matches!(back, Ok(ref outcome) if outcome.status == EvolutionStatus::AlreadySo),
        "re-saving the applied relays over a pending change of them answered already so",
    );
}

/// Re-saving the relays a circle has applied while this device's change of
/// them waits in the engine's queue is not "already so": the queued change
/// would still apply later, moving the circle to relays the user just turned
/// away from while the app said nothing changed.
#[tokio::test]
async fn re_saving_the_applied_relays_while_a_change_of_them_is_queued_is_not_already_so() {
    let Gated { bob, group, .. } = a_circle_whose_changes_queue().await;
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let widened = changes
        .update_relays(&bob.circle, &group, &[ONE.to_string(), THREE.to_string()])
        .await
        .expect("the save is answered");
    assert_eq!(
        widened.status,
        EvolutionStatus::Queued,
        "premise: the change waits in the engine's queue"
    );

    let back = changes
        .update_relays(&bob.circle, &group, &[ONE.to_string()])
        .await;
    assert!(
        !matches!(back, Ok(ref outcome) if outcome.status == EvolutionStatus::AlreadySo),
        "re-saving the applied relays over a queued change of them answered already so",
    );
}

/// A store that cannot say whether a commit of this device's is pending or
/// queued answers that one may be: re-saving the applied relays then goes to
/// the engine, never "already so".
#[tokio::test]
async fn a_save_the_store_cannot_judge_is_never_already_so() {
    let fx = setup_circle(2, &[ONE, TWO]).await;
    let (admin, _others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    admin
        .session()
        .fail_store_for_test(StoreFault::OwnCommit, true);

    let outcome = through(&transport, &outbox, &clock)
        .update_relays(&admin.circle, &group, &[ONE.to_string(), TWO.to_string()])
        .await;
    assert!(
        !matches!(outcome, Ok(ref outcome) if outcome.status == EvolutionStatus::AlreadySo),
        "a save answered already so on a store that could not be read",
    );
}

/// An admin's leave in two changes: a successor is promoted, then the caller
/// steps down. Each is one call, applied on an acknowledgement.
#[tokio::test]
async fn a_handoff_and_a_self_demote_are_each_one_call() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let successor = &others[0];
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let promoted = changes
        .admin_handoff(&admin.circle, &group, &successor.keys.public_key())
        .await
        .expect("the handoff is accepted");
    assert_eq!(promoted.status, EvolutionStatus::Confirmed);
    let admins = admin.session().admin_pubkeys(&group).await.expect("admins");
    assert_eq!(admins.len(), 2);

    clock.set(SECOND_MS);
    let demoted = changes
        .self_demote(&admin.circle, &group)
        .await
        .expect("the demotion is accepted");
    assert_eq!(demoted.status, EvolutionStatus::Confirmed);
    assert_eq!(
        admin.session().admin_pubkeys(&group).await.expect("admins"),
        [successor.keys.public_key().to_bytes()]
    );
    assert_eq!(transport.calls().len(), 2);
}

// ── Older records first; what a confirm replays ──────────────────────────────

/// A change first resumes its circle's older records, as MDK's host does:
/// the commit still awaiting relays is sent again and applied before the new
/// one is staged behind it. And what that confirm replays — a peer's
/// location that had waited unread behind the pending commit — is stored,
/// stamps the circle as one a peer is still arriving in, and comes back in
/// the outcome of the call that resolved it.
#[tokio::test]
async fn an_evolution_first_resumes_its_groups_older_fanouts_and_returns_what_they_replay() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let ngid = nostr_group_id(&admin, &group).await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let first = changes
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("accepted");
    assert_eq!(first.status, EvolutionStatus::Unresolved);
    let (_, older) = the_row(&admin, &group).await;
    // A peer's fix arrives while the commit is pending: held unread.
    let fix = seal(&others[0], &group).await.expect("a peer seals");
    assert!(
        admin
            .circle
            .ingest_for_test(&fix)
            .await
            .expect("the ingest runs")
            .is_empty(),
        "premise: a location behind a pending commit is held",
    );
    assert!(
        admin
            .circle
            .circle_health(&ngid)
            .expect("health")
            .last_peer_event_at_ms
            .is_none(),
        "premise: nothing has arrived yet as far as the circle's health knows",
    );
    transport.calls();

    // The next change, with the relay back.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let second = changes
        .update_relays(&admin.circle, &group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("accepted");
    assert_eq!(second.status, EvolutionStatus::Confirmed);
    let sent = transport.calls();
    assert_eq!(sent.len(), 2);
    assert_eq!(
        sent[0].event_id, older.event_id,
        "a change was staged before its circle's older commit was sent again",
    );
    assert_ne!(sent[1].event_id, older.event_id);
    assert!(!roster(&admin, &group)
        .await
        .contains(&others[1].pubkey_hex()));

    // The fix the older confirm replayed: returned, stored, and stamped.
    assert_eq!(
        second
            .replayed
            .iter()
            .filter(|result| matches!(result, LocationMessageResult::Location { .. }))
            .count(),
        1,
        "a fix replayed inside a confirm did not reach the outcome of the call that made it",
    );
    assert_eq!(
        admin
            .circle
            .snapshot_last_known_for_circle(&ngid, chrono::Utc::now().timestamp())
            .expect("the store is read")
            .len(),
        1,
        "a fix replayed inside a confirm was not stored",
    );
    assert!(
        admin
            .circle
            .circle_health(&ngid)
            .expect("health")
            .last_peer_event_at_ms
            .is_some(),
        "a fix replayed inside a confirm did not stamp the circle as one a peer arrives in",
    );
}

/// What a call's own engine work hands back the legacy way is disposed of
/// under Rule 13 by that call. A sole admin's circle is send-gated by a
/// commit from an epoch it has not reached, and a removal waits queued
/// behind it. The missing commit arrives and the user asks for the repair:
/// its advance applies what was waiting, the engine releases the removal,
/// and it is recorded in the hold that released it and driven by the call
/// that asked — never handed to the publisher of what has no record.
async fn the_deferred_send_repair_in_a_wake(
    room_ms: Option<u64>,
) -> (
    CircleMember,
    GroupId,
    String,
    Vec<(nostr::Event, Vec<String>)>,
    usize,
) {
    use haven_core::nostr::mls::types::SendIntent;

    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let behind = admin.session().epoch(&group).await.expect("epoch");
    // A member commits twice; the admin holds only the second.
    let mut commits = Vec::new();
    for _ in 0..2 {
        let effects = others[0]
            .session()
            .send(SendIntent::SelfUpdate {
                group_id: group.clone(),
            })
            .await
            .expect("a self-update");
        let (msg, pending) = effects
            .publish
            .iter()
            .find_map(|work| match work {
                PublishWork::GroupEvolution { msg, pending, .. } => Some((msg.clone(), *pending)),
                _ => None,
            })
            .expect("one staged change");
        others[0]
            .session()
            .confirm_published(pending)
            .await
            .expect("confirm");
        commits.push(SessionManager::transport_message_to_event(&msg).expect("an event"));
    }
    let row = others[0]
        .session()
        .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, behind + 1)
        .await
        .expect("the commit at the higher epoch");
    admin
        .session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("the admin holds the future-epoch commit");

    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::ahead_of_the_device(3 * DAY_MS);
    let changes = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: &clock,
        deadline_ms: room_ms.map(|room| clock.now_ms() + room),
        mode: &DriveMode::Full,
    };
    let removed = others[1].pubkey_hex();
    let queued = changes
        .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
        .await
        .expect("accepted");
    assert_eq!(queued.status, EvolutionStatus::Queued);
    // The missing commit arrives, and waits out the engine's own deadline.
    admin
        .session()
        .process_event(&commits[0])
        .await
        .expect("the ingest runs");
    if let Some(wait) = admin.session().receive_retick_after(&group).await {
        tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
    }

    let outcome = changes
        .repair_rotation(&admin.circle, &group)
        .await
        .expect("the repair runs");
    assert!(
        matches!(outcome, RepairOutcome::Deferred { .. }),
        "premise: a send-gated circle gets the deferred-send repair",
    );
    let sent = transport.calls().len();
    (admin, group, removed, outbox.handed(), sent)
}

/// Re-authored when the deferred-send repair left the publish ladder: the
/// commit it releases used to be handed to the publisher of unrecorded
/// things and resolved on its word; it is now recorded in the hold that
/// released it and sent by the driver, like every other commit.
#[tokio::test]
async fn a_commit_the_deferred_send_repair_releases_is_recorded_and_driven_by_the_same_call() {
    let (admin, group, removed, handed, sent) = the_deferred_send_repair_in_a_wake(None).await;
    assert_eq!(
        sent, 1,
        "the removal the repair released was not sent under its record"
    );
    assert!(
        handed.iter().all(|(event, _)| event.kind.as_u16() != 445),
        "a commit the repair released was handed to the publisher of what has no record",
    );
    assert!(
        !roster(&admin, &group).await.contains(&removed)
            && staged_ref(&admin, &group).await.is_none(),
        "the removal the repair released was left unresolved, or owed the legacy way",
    );
}

/// The wake's budget bounds that drive too: with less left than a row needs,
/// the commit the repair released is recorded and not begun. It is neither
/// sent nor rolled back — staged under its record, for the next drive, which
/// is more than a wake the system ended used to leave.
#[tokio::test]
async fn a_commit_the_repair_releases_is_recorded_and_not_begun_in_a_wake_with_no_room_for_it() {
    let (admin, group, _removed, handed, sent) =
        the_deferred_send_repair_in_a_wake(Some(ROW_BUDGET_MS - 1)).await;
    assert!(
        sent == 0 && handed.iter().all(|(event, _)| event.kind.as_u16() != 445),
        "a call was begun that the wake could not have waited out",
    );
    let (_, record) = the_row(&admin, &group).await;
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && record.mls == FanoutMls::Pending
            && record
                .statuses
                .iter()
                .all(|status| *status == FanoutTargetStatus::NotAttempted),
        "a commit the wake had no room to send was resolved, or left without its record",
    );
}

// ── Queued ───────────────────────────────────────────────────────────────────

/// A circle of three in which the second member is an admin too, and holds a
/// commit of the first's from an epoch it has not reached: every change it
/// asks for is queued by the engine until `opens_the_gate` reaches it.
struct Gated {
    bob: CircleMember,
    carol: CircleMember,
    group: GroupId,
    opens_the_gate: nostr::Event,
}

async fn a_circle_whose_changes_queue() -> Gated {
    let fx = setup_circle(3, &[ONE]).await;
    let (alice, mut others, group) = split(fx);
    let carol = others.remove(1);
    let bob = others.remove(0);
    // Bob becomes a second admin.
    let promote = alice
        .circle
        .admin_handoff_for_test(&group, &bob.keys.public_key())
        .await
        .expect("promote");
    for member in [&bob, &carol] {
        member
            .session()
            .process_event_settled_for_test(&promote)
            .await
            .expect("applies the promotion");
    }
    // Alice commits twice; Bob holds only the second.
    let first = alice
        .circle
        .update_relays_for_test(&group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change");
    let tip = alice.circle.group_epoch(&group).await.expect("epoch");
    alice
        .circle
        .update_relays_for_test(&group, &[ONE.to_string()])
        .await
        .expect("a second relay change");
    let row = alice
        .session()
        .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, tip)
        .await
        .expect("alice's commit at the higher epoch");
    bob.session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("bob holds the future-epoch commit");
    Gated {
        bob,
        carol,
        group,
        opens_the_gate: first,
    }
}

/// A change the engine queues is accepted and durable. It is reported as
/// queued — not as a failure, and not as an error — for a removal and for an
/// invite alike, and nothing is sent for it yet.
#[tokio::test]
async fn a_queued_add_or_remove_is_reported_queued_never_failed() {
    for invite in [false, true] {
        let Gated {
            bob, carol, group, ..
        } = a_circle_whose_changes_queue().await;
        let transport = ScriptedFanout::default();
        let outbox = Outbox::default();
        let clock = Clock::at(0);
        let changes = through(&transport, &outbox, &clock);

        let outcome = if invite {
            let (_invitee, package) = an_invitee().await;
            changes.add_members(&bob.circle, &group, &[package]).await
        } else {
            changes
                .remove_members(&bob.circle, &group, &[carol.pubkey_hex()])
                .await
        }
        .unwrap_or_else(|_| panic!("a queued change was reported as an error"));

        assert_eq!(outcome.status, EvolutionStatus::Queued);
        assert_eq!(
            (outcome.welcomes_sent, outcome.welcomes_total),
            (0, usize::from(invite))
        );
        assert_eq!(
            bob.session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("the queue"),
            1,
            "a change reported as queued is not in the engine's queue",
        );
        assert!(roster(&bob, &group).await.contains(&carol.pubkey_hex()));
        assert!(transport.calls().is_empty() && outbox.handed().is_empty());
        assert!(rows_of(&bob, &group).await.is_empty());
    }
}

/// A removal the engine queued has removed nobody yet: its member is still in
/// the circle, still sent its locations, and stays in the directory. When the
/// removal is applied later the row goes outright — a reconcile after it
/// lands would only demote a row it finds, so the confirm deletes it.
#[tokio::test]
async fn a_queued_remove_that_later_confirms_deletes_the_directory_row() {
    let Gated {
        bob,
        carol,
        group,
        opens_the_gate,
    } = a_circle_whose_changes_queue().await;
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    bob.circle
        .reconcile_member_directory(
            haven_core::circle::DirectoryReconcile::Rewrite,
            chrono::Utc::now().timestamp(),
        )
        .await
        .expect("the directory is written");
    assert!(directory(&bob).contains(&carol.pubkey_hex()), "premise");
    let queued = through(&transport, &outbox, &clock)
        .remove_members(&bob.circle, &group, &[carol.pubkey_hex()])
        .await
        .expect("accepted");
    assert_eq!(queued.status, EvolutionStatus::Queued);
    assert!(
        directory(&bob).contains(&carol.pubkey_hex()),
        "a removal that is only queued took its member out of the directory while \
         the circle still sends them its locations",
    );

    // The gate opens; a reconcile finds Carol still on the roster.
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("bob reaches the epoch his gate waited for");
    bob.circle
        .reconcile_member_directory(
            haven_core::circle::DirectoryReconcile::Rewrite,
            chrono::Utc::now().timestamp(),
        )
        .await
        .expect("the directory is written");
    assert!(
        directory(&bob).contains(&carol.pubkey_hex()),
        "premise: a reconcile while the removal waits writes the row back",
    );

    // The removal is released under its record, and applied on an ack.
    let released = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .unwrap_or_else(|_| panic!("the driving advance runs"));
    assert_eq!(
        released.fanouts.len(),
        1,
        "premise: the queued removal is released as one recorded change"
    );
    transport.answer(ONE, [Answer::Accepted]);
    let _ = through(&transport, &outbox, &clock)
        .resume(&bob.circle)
        .await;
    assert!(!roster(&bob, &group).await.contains(&carol.pubkey_hex()));
    assert!(
        !directory(&bob).contains(&carol.pubkey_hex()),
        "a member removed by a queued removal was demoted in the directory, not deleted",
    );
}

/// A removal confirmed after a restart announces only that the epoch moved:
/// who a commit removed the engine says from memory it does not rebuild at an
/// open. The driver's confirm reads the intent the engine keeps for the
/// commit, and the member's directory row goes outright all the same —
/// whether the process died before the commit was first sent or after.
#[tokio::test]
async fn a_removal_confirmed_after_a_restart_deletes_its_members_directory_row() {
    for sent_before_the_kill in [false, true] {
        let Gated {
            bob,
            carol,
            group,
            opens_the_gate,
        } = a_circle_whose_changes_queue().await;
        let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
        let outbox = Outbox::default();
        let clock = Clock::at(0);
        let queued = through(&transport, &outbox, &clock)
            .remove_members(&bob.circle, &group, &[carol.pubkey_hex()])
            .await
            .expect("accepted");
        assert_eq!(queued.status, EvolutionStatus::Queued);
        bob.session()
            .process_event_settled_for_test(&opens_the_gate)
            .await
            .expect("the gate opens");
        let released = bob
            .session()
            .advance_for_drive(&group, clock.now_ms())
            .await
            .expect("the advance runs");
        let [id] = <[FanoutId; 1]>::try_from(released.fanouts)
            .unwrap_or_else(|_| panic!("the queued removal was not released under one record"));
        if sent_before_the_kill {
            let waiting = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
                .await
                .unwrap_or_else(|_| panic!("the record is driven"));
            assert_eq!(waiting.status, FanoutStatus::Unresolved);
        }

        let bob = bob.reopen();
        bob.circle
            .reconcile_member_directory(
                haven_core::circle::DirectoryReconcile::Rewrite,
                chrono::Utc::now().timestamp(),
            )
            .await
            .expect("the directory is written");
        assert!(
            directory(&bob).contains(&carol.pubkey_hex()),
            "premise: listed while the removal waits",
        );
        for relay in [ONE, TWO] {
            transport.answer(relay, [Answer::Accepted]);
        }
        clock.set(HOUR_MS);
        let applied = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .unwrap_or_else(|_| panic!("the restored record is driven"));
        assert_eq!(applied.status, FanoutStatus::Confirmed);
        assert!(!roster(&bob, &group).await.contains(&carol.pubkey_hex()));
        assert!(
            !directory(&bob).contains(&carol.pubkey_hex()),
            "a member removed by a removal confirmed after a restart was demoted in the \
             directory, not deleted (sent before the kill: {sent_before_the_kill})",
        );
    }
}

/// A change the engine had queued and later released keeps a link the
/// confirm deletes in its own transaction. When that confirm fails after the
/// merge, the finishing confirm cannot succeed in the same session: the
/// engine asks its store to delete the link again and is refused. Nothing in
/// Haven classifies that error. (The commit is recorded here through the
/// seam that leaves the queued copy in place; a plane that drives retires it
/// in the hold that records the commit, and is not left in this state.) What
/// holds: the commit reads applied, the
/// circle stays `PendingPublish` for the rest of the session, no other
/// circle's commit waits behind it, and the next open finds it finished.
#[tokio::test]
async fn a_queue_released_commit_whose_confirm_failed_after_its_merge_is_finished_by_the_next_open()
{
    let Gated {
        bob,
        carol,
        group,
        opens_the_gate,
    } = a_circle_whose_changes_queue().await;
    let (db, key) = db_of(&bob);
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let queued = bob
        .session()
        .remove_members(&group, &[carol.pubkey_hex()])
        .await;
    assert!(
        queued
            .as_ref()
            .is_ok_and(|effects| !effects.queued.is_empty()),
        "premise: the removal is queued",
    );
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("the gate opens");
    let source = bob.session().epoch(&group).await.expect("epoch");
    let released = bob
        .session()
        .advance_convergence(&group)
        .await
        .expect("advance");
    let [id] = <[FanoutId; 1]>::try_from(
        bob.session()
            .stage_commits_for_test(released, clock.now_ms())
            .await
            .fanouts,
    )
    .unwrap_or_else(|_| panic!("premise: the queued removal was released and recorded"));

    // Acknowledged; the confirm fails after its merge.
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, true).expect("arm");
    let failed = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("a commit applied beside an error was reported as the error"));
    set_epoch_anchor_write_fault_for_test(&db, &key, source + 1, false).expect("disarm");
    assert!(failed.error.is_some(), "premise: the confirm failed");
    assert_eq!(failed.status, FanoutStatus::Confirmed);

    // With nothing failing any more, the finishing confirm is still refused.
    for seconds in [1, 2] {
        clock.set(seconds * SECOND_MS);
        let outcome = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .unwrap_or_else(|_| panic!("an applied commit was reported as an error"));
        assert_eq!(outcome.status, FanoutStatus::Confirmed);
        assert!(
            outcome.error.is_some() && staged_ref(&bob, &group).await.is_some(),
            "the finishing confirm of a queue-released commit succeeded in the session: \
             MDK's queued-intent delete has become idempotent, and this residual is gone",
        );
    }
    assert!(!can_send(&bob, &group).await);

    // Another circle's commit does not wait behind it.
    let relays = vec![TWO.to_string()];
    let elsewhere = bob
        .circle
        .create_circle(
            &bob.keys,
            Vec::new(),
            &haven_core::circle::CircleConfig::new("Solo").with_relays(relays.clone()),
        )
        .await
        .expect("a second circle")
        .circle
        .mls_group_id;
    clock.set(3 * SECOND_MS);
    let other = through(&transport, &outbox, &clock)
        .update_relays(
            &bob.circle,
            &elsewhere,
            &[TWO.to_string(), THREE.to_string()],
        )
        .await
        .expect("accepted");
    assert_eq!(other.status, EvolutionStatus::Confirmed);
    let resumed = through(&transport, &outbox, &clock)
        .resume(&bob.circle)
        .await;
    assert!(
        resumed.errored,
        "premise: the unfinishable confirm is still an error"
    );

    // The next open finds nothing staged: the commit was merged in the store.
    let bob = bob.reopen();
    assert!(
        staged_ref(&bob, &group).await.is_none() && can_send(&bob, &group).await,
        "a commit merged in the store was still held after a reopen",
    );
    assert!(!roster(&bob, &group).await.contains(&carol.pubkey_hex()));
}

/// A change the engine queued and later released is retired from the queue
/// in the hold that records its commit: the record is its durable form from
/// then on. So a commit restored after a kill — which the engine confirms
/// without the link to its queued change, kept in memory only — leaves
/// nothing behind to be made a second time, and the circle's later advances
/// run.
#[tokio::test]
async fn a_restored_released_intent_is_not_released_again_after_its_confirm() {
    let Gated {
        bob,
        carol,
        group,
        opens_the_gate,
    } = a_circle_whose_changes_queue().await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let queued = through(&transport, &outbox, &clock)
        .remove_members(&bob.circle, &group, &[carol.pubkey_hex()])
        .await
        .expect("accepted");
    assert_eq!(queued.status, EvolutionStatus::Queued);
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("the gate opens");
    let queue = |member: &CircleMember| {
        let circle = Arc::clone(&member.circle);
        let group = group.clone();
        async move {
            circle
                .session()
                .queued_intent_count_for_test(&group)
                .await
                .expect("the queue")
        }
    };
    assert_eq!(queue(&bob).await, 1, "premise: the removal is queued");

    // Released by a plane that drives, and recorded in that hold.
    let released = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    let [id] = <[FanoutId; 1]>::try_from(released.fanouts)
        .unwrap_or_else(|_| panic!("the queued removal was not released under one record"));
    assert_eq!(
        queue(&bob).await,
        0,
        "a released change was left in the queue beside its commit's record",
    );

    // Killed before any relay answered; restored, sent and applied.
    let bob = bob.reopen();
    assert!(
        staged_ref(&bob, &group).await.is_some(),
        "premise: restored"
    );
    let outcome = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the restored record was not driven"));
    assert_eq!(outcome.status, FanoutStatus::Confirmed);
    assert!(!roster(&bob, &group).await.contains(&carol.pubkey_hex()));

    // Nothing is left to be made a second time, in this session or the next.
    nothing_is_left_to_release(&bob, &group, clock.now_ms()).await;
    nothing_is_left_to_release(&bob.reopen(), &group, clock.now_ms()).await;
}

async fn nothing_is_left_to_release(bob: &CircleMember, group: &GroupId, now_ms: u64) {
    let again = bob
        .session()
        .advance_for_drive(group, now_ms)
        .await
        .expect("a later advance runs");
    let queued = bob
        .session()
        .queued_intent_count_for_test(group)
        .await
        .expect("the queue");
    assert!(
        again.fanouts.is_empty() && queued == 0,
        "a confirmed queued change was released a second time",
    );
    assert!(
        bob.session().advance_convergence(group).await.is_ok(),
        "the circle's full advance fails after a restored queued change was confirmed",
    );
    assert!(staged_ref(bob, group).await.is_none() && can_send(bob, group).await);
}

/// The same change asked twice is queued twice, and once the first is made
/// the second never can be. The hold that records the first one's commit
/// retires every queued copy of it, so the twin is not left to fail the
/// circle's queue: the next full advance runs, and nothing waits behind it.
#[tokio::test]
async fn a_change_asked_twice_is_retired_with_its_twin() {
    let Gated {
        bob,
        carol,
        group,
        opens_the_gate,
    } = a_circle_whose_changes_queue().await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    for _ in 0..2 {
        let queued = bob
            .session()
            .remove_members(&group, &[carol.pubkey_hex()])
            .await;
        assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    }
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("the gate opens");
    let released = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    let [id] = <[FanoutId; 1]>::try_from(released.fanouts)
        .unwrap_or_else(|_| panic!("premise: the removal is released once"));
    assert_eq!(
        bob.session()
            .queued_intent_count_for_test(&group)
            .await
            .expect("the queue"),
        0,
        "the twin of a recorded change was left in the queue",
    );
    let applied = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the removal is applied"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    assert!(
        bob.session().advance_convergence(&group).await.is_ok(),
        "a change asked twice left a copy that fails the circle's every full advance",
    );
    assert!(bob.session().peek_change_notes(&group).is_empty());
    assert!(can_send(&bob, &group).await);
}

/// A circle of four whose second member is an admin too and holds a commit
/// of the first's from an epoch it has not reached, so that every change it
/// asks for is queued until `first` reaches it.
struct GatedFour {
    alice: CircleMember,
    bob: CircleMember,
    carol: CircleMember,
    dave: CircleMember,
    group: GroupId,
    /// Alice's first commit: Bob holds only her second, and applies both
    /// once this one reaches him.
    first: nostr::Event,
}

/// What Alice's second commit — the one Bob holds from an epoch he has not
/// reached — does.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Second {
    ChangesRelays,
    RemovesCarol,
    DemotesBob,
}

#[allow(clippy::too_many_lines)]
async fn a_circle_of_four_whose_changes_queue(second: Second) -> GatedFour {
    let fx = setup_circle(4, &[ONE]).await;
    let (alice, mut others, group) = split(fx);
    let dave = others.remove(2);
    let carol = others.remove(1);
    let bob = others.remove(0);
    let promote = alice
        .circle
        .admin_handoff_for_test(&group, &bob.keys.public_key())
        .await
        .expect("promote");
    for member in [&bob, &carol, &dave] {
        member
            .session()
            .process_event_settled_for_test(&promote)
            .await
            .expect("applies the promotion");
    }
    let first = alice
        .circle
        .update_relays_for_test(&group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change");
    let tip = alice.circle.group_epoch(&group).await.expect("epoch");
    let second = match second {
        Second::ChangesRelays => {
            let commit = alice
                .circle
                .update_relays_for_test(&group, &[ONE.to_string()])
                .await
                .expect("a second relay change");
            commit
        }
        Second::RemovesCarol => {
            let commit = alice
                .circle
                .remove_members_for_test(&group, &[carol.pubkey_hex()])
                .await
                .expect("alice removes carol");
            commit
        }
        Second::DemotesBob => {
            let staged = alice
                .session()
                .update_admin_policy(&group, &[alice.keys.public_key().to_bytes()])
                .await
                .expect("alice takes bob out of the admins");
            let (commit, pending) = staged
                .publish
                .iter()
                .find_map(|work| match work {
                    PublishWork::GroupEvolution { msg, pending, .. } => Some((
                        SessionManager::transport_message_to_event(msg).expect("the commit"),
                        *pending,
                    )),
                    _ => None,
                })
                .expect("the demotion's commit");
            alice
                .circle
                .session()
                .confirm_published(pending)
                .await
                .expect("confirm");
            commit
        }
    };
    let row = alice
        .session()
        .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, tip)
        .await
        .expect("alice's commit at the higher epoch");
    bob.session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("bob holds the future-epoch commit");
    for member in [&carol, &dave] {
        for commit in [&first, &second] {
            // Carol does not apply her own removal the way a member does.
            let _ = member
                .session()
                .process_event_settled_for_test(commit)
                .await;
        }
    }
    GatedFour {
        alice,
        bob,
        carol,
        dave,
        group,
        first,
    }
}

async fn queue_len(member: &CircleMember, group: &GroupId) -> usize {
    member
        .session()
        .queued_intent_count_for_test(group)
        .await
        .expect("the queue")
}

/// A queued change that can no longer be made does NOT hold back the
/// eviction of a member who left: the engine runs its own maintenance before
/// it prepares anything queued. What such a change does hold is the queue —
/// the advance that would drain it fails each time — and the circle is told
/// so, in a note and in a log line that name nothing. Here the change is one
/// nothing Haven reads can judge: a hand-over to a member who has since been
/// removed.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_due_eviction_is_staged_and_driven_past_a_queued_change_that_cannot_be_made() {
    let GatedFour {
        alice,
        bob,
        carol,
        dave,
        group,
        first,
    } = a_circle_of_four_whose_changes_queue(Second::ChangesRelays).await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    // Queued: Carol's removal, then a hand-over to Carol.
    let queued = bob
        .session()
        .remove_members(&group, &[carol.pubkey_hex()])
        .await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    let mut admins = bob.session().admin_pubkeys(&group).await.expect("admins");
    admins.push(carol.keys.public_key().to_bytes());
    let queued = bob.session().update_admin_policy(&group, &admins).await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    bob.session()
        .process_event_settled_for_test(&first)
        .await
        .expect("the gate opens");
    let released = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    let [removal] = <[FanoutId; 1]>::try_from(released.fanouts)
        .unwrap_or_else(|_| panic!("premise: the removal is released"));
    let applied = drive_one(&bob.circle, &transport, &clock, &removal, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("premise: the removal is applied"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    let sent = transport.calls();
    let removal = <nostr::Event as nostr::JsonUtil>::from_json(&sent[0].payload).expect("event");
    dave.session()
        .process_event_settled_for_test(&removal)
        .await
        .expect("dave follows the removal");
    drop(alice);

    // The hand-over to somebody who is gone is still queued, and fails the
    // queue's drain.
    assert_eq!(queue_len(&bob, &group).await, 1, "premise: still queued");
    let mut advanced = None;
    let lines = capture_haven_log(async {
        advanced = Some(
            bob.session()
                .advance_for_drive(&group, clock.now_ms())
                .await,
        );
    })
    .await;
    assert!(
        advanced.is_some_and(|advanced| advanced.is_ok_and(|staged| staged.fanouts.is_empty())),
        "one queued change that cannot be made stopped its circle's advance",
    );
    let said = line_saying(&lines, "a circle's full advance failed");
    assert_eq!(said.level, log::Level::Warn);
    assert!(
        said.message.ends_with("unknown_member"),
        "the line does not say what kind of failure it was",
    );
    assert_no_needles(
        std::slice::from_ref(said),
        &[
            &hex::encode(group.as_slice()),
            &carol.pubkey_hex(),
            &bob.pubkey_hex(),
            CANARY,
        ],
    );
    assert_eq!(
        bob.session().peek_change_notes(&group),
        [ChangeNote::QueuedChangesHeld],
        "a circle whose queue cannot drain was not told",
    );
    assert_eq!(
        queue_len(&bob, &group).await,
        1,
        "a change nothing judged was retired"
    );

    // Dave leaves; his eviction falls due and is staged and applied.
    let left = dave
        .session()
        .leave_group(&group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let leave = SessionManager::proposal_events(&left.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    bob.session()
        .process_event(&leave)
        .await
        .expect("the leave is ingested");
    let mut eviction = None;
    for _ in 0..8 {
        if let Some(wait) = bob.session().eviction_due_after_for_test(&group).await {
            tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
        }
        let staged = bob
            .session()
            .advance_for_drive(&group, clock.now_ms())
            .await
            .expect("the advance runs");
        if let Some(id) = staged.fanouts.into_iter().next() {
            eviction = Some(id);
            break;
        }
    }
    let eviction = eviction.unwrap_or_else(|| {
        panic!(
            "a due eviction waits behind a queued change that cannot be made: MDK's drain \
             order changed — correct T-QUEUED-INTENT-RESTORE"
        )
    });
    let evicted = drive_one(&bob.circle, &transport, &clock, &eviction, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the eviction is driven"));
    assert_eq!(evicted.status, FanoutStatus::Confirmed);
    assert!(!roster(&bob, &group).await.contains(&dave.pubkey_hex()));
}

/// A removal queued for a member whom another admin then removes is moot,
/// and dangerous to keep: the engine would prepare it again at every full
/// advance, fail while the member is gone, and REMOVE them the day they are
/// invited back. Before a full advance it is retired, its circle told, and
/// the member's directory row deleted — so a member invited back afterwards
/// stays. A removal that can still be made is kept.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_member_invited_back_is_not_removed_by_a_removal_queued_before_they_left() {
    let GatedFour {
        alice,
        bob,
        carol,
        dave,
        group,
        first,
    } = a_circle_of_four_whose_changes_queue(Second::RemovesCarol).await;
    let clock = Clock::at(0);
    for target in [&carol, &dave] {
        let queued = bob
            .session()
            .remove_members(&group, &[target.pubkey_hex()])
            .await;
        assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    }
    bob.circle
        .reconcile_member_directory(
            haven_core::circle::DirectoryReconcile::Rewrite,
            chrono::Utc::now().timestamp(),
        )
        .await
        .expect("the directory is written");

    // While the gate is shut nothing is judged unmakeable.
    let held = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    assert!(held.fanouts.is_empty());
    assert_eq!(
        (
            queue_len(&bob, &group).await,
            bob.session().peek_change_notes(&group)
        ),
        (2, Vec::new()),
        "a queued removal that can still be made was retired",
    );

    // Alice has removed Carol herself; Bob learns of it.
    drop(alice);
    bob.session()
        .process_event_settled_for_test(&first)
        .await
        .expect("bob follows alice");
    assert!(
        !roster(&bob, &group).await.contains(&carol.pubkey_hex()),
        "premise"
    );
    assert_eq!(
        queue_len(&bob, &group).await,
        2,
        "premise: both still queued"
    );

    // The next advance of a plane that drives retires the moot removal and
    // releases the one that can still be made.
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let advanced = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    let [still_makeable] = <[FanoutId; 1]>::try_from(advanced.fanouts)
        .unwrap_or_else(|_| panic!("the removal that can still be made was not released"));
    bob.circle
        .reconcile_member_directory(
            haven_core::circle::DirectoryReconcile::Rewrite,
            chrono::Utc::now().timestamp(),
        )
        .await
        .expect("the directory is written");
    assert_eq!(
        bob.session().peek_change_notes(&group),
        [ChangeNote::QueuedChangeDropped],
        "a queued change retired unmade was not told to its circle",
    );
    assert!(
        !directory(&bob).contains(&carol.pubkey_hex()),
        "a member whose queued removal became moot was left in the directory",
    );
    let applied = drive_one(
        &bob.circle,
        &transport,
        &clock,
        &still_makeable,
        &DriveMode::Full,
    )
    .await
    .unwrap_or_else(|_| panic!("the remaining removal is driven"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    assert!(!roster(&bob, &group).await.contains(&dave.pubkey_hex()));
    assert_eq!(queue_len(&bob, &group).await, 0);

    // Carol is invited back, by Bob. Nothing removes her again.
    let inbox = vec![INBOX.to_string()];
    let package = MemberKeyPackage {
        key_package_event: create_key_package_event(carol.session(), &carol.keys, &inbox).await,
        inbox_relays: inbox,
        nip65_relays: Vec::new(),
    };
    let invited = through(&transport, &outbox, &clock)
        .add_members(&bob.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(invited.status, EvolutionStatus::Confirmed);
    assert!(roster(&bob, &group).await.contains(&carol.pubkey_hex()));
    for _ in 0..3 {
        let again = bob
            .session()
            .advance_for_drive(&group, clock.now_ms())
            .await
            .expect("the advance runs");
        assert!(again.fanouts.is_empty());
        assert!(bob.session().advance_convergence(&group).await.is_ok());
    }
    assert!(
        roster(&bob, &group).await.contains(&carol.pubkey_hex())
            && staged_ref(&bob, &group).await.is_none(),
        "a member invited back was removed by a removal queued before they left",
    );
}

/// The queue is judged as the engine will meet it. An invite of somebody
/// followed by their removal is a removal that CAN be made when its turn
/// comes, though its member is not in the circle today: the check stops at
/// the invite, which is kept, and the removal stays queued behind it.
/// Retired as moot, the invite would stand alone and the person the user
/// last asked to have removed would end up in the circle.
#[tokio::test]
async fn a_removal_queued_behind_an_invite_of_the_same_person_is_not_retired_as_moot() {
    let GatedFour {
        alice,
        bob,
        group,
        first,
        ..
    } = a_circle_of_four_whose_changes_queue(Second::ChangesRelays).await;
    let clock = Clock::at(0);
    let eve = CircleMember::new();
    let inbox = vec![INBOX.to_string()];
    let package = SessionManager::key_package_from_event(
        &create_key_package_event(eve.session(), &eve.keys, &inbox).await,
    )
    .expect("a key package");
    let invite = bob.session().add_members(&group, vec![package]).await;
    assert!(invite.is_ok_and(|effects| !effects.queued.is_empty()));
    bob.session()
        .queue_removal_intent_for_test(&group, &[eve.pubkey_hex()])
        .await
        .expect("the removal is queued behind the invite");
    assert_eq!(queue_len(&bob, &group).await, 2, "premise");

    drop(alice);
    bob.session()
        .process_event_settled_for_test(&first)
        .await
        .expect("bob follows alice");
    let advanced = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");

    assert_eq!(
        advanced.fanouts.len(),
        1,
        "the invite at the head of the queue was not released",
    );
    assert_eq!(
        (
            queue_len(&bob, &group).await,
            bob.session().peek_change_notes(&group)
        ),
        (1, Vec::new()),
        "a removal queued behind an invite of the same person was judged against a \
         roster the invite had not yet changed",
    );
}

/// With an eviction of this device's own left staged under no ref — a
/// process that died before its obligation was written — the roster the
/// engine reports already omits the member who left, while they are still in
/// the circle. A removal of that member the user queued is not moot, and is
/// not retired as one.
#[tokio::test]
async fn a_queued_removal_of_a_leaver_is_kept_while_their_eviction_is_left_staged() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let leaver = others.remove(1);
    let left = leaver
        .session()
        .leave_group(&group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let leave = SessionManager::proposal_events(&left.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    admin
        .session()
        .process_event(&leave)
        .await
        .expect("the leave is ingested");
    for _ in 0..8 {
        if staged_ref(&admin, &group).await.is_some() {
            break;
        }
        if let Some(wait) = admin.session().receive_retick_after(&group).await {
            tokio::time::sleep(wait).await;
        }
        let _ = admin.session().stage_unrecorded_for_test(&group).await;
    }
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "premise: staged"
    );
    let admin = admin.reopen();
    assert!(
        matches!(
            admin.session().epoch_state(&group).await,
            Some(EpochState::Stable { .. })
        ) && !roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "premise: the circle reads stable and its roster is the staged commit's",
    );
    admin
        .session()
        .queue_removal_intent_for_test(&group, &[leaver.pubkey_hex()])
        .await
        .expect("the removal is queued");

    admin
        .session()
        .retire_unmakeable_queued_changes_for_test(&group)
        .await;

    assert_eq!(
        (
            queue_len(&admin, &group).await,
            admin.session().peek_change_notes(&group)
        ),
        (1, Vec::new()),
        "a removal of a member who is still in the circle was retired as moot",
    );
}

/// The same, where every queued change of the circle is retired whatever
/// the roster says: the removal of the member the staged eviction omits is
/// said as a removal, and the member is kept and holds the circle — they are
/// still in it until that eviction is made.
#[tokio::test]
async fn a_queued_removal_retired_while_an_eviction_is_left_staged_keeps_its_member() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let leaver = others.remove(1);
    let left = leaver
        .session()
        .leave_group(&group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let leave = SessionManager::proposal_events(&left.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    admin
        .session()
        .process_event(&leave)
        .await
        .expect("the leave is ingested");
    for _ in 0..8 {
        if staged_ref(&admin, &group).await.is_some() {
            break;
        }
        if let Some(wait) = admin.session().receive_retick_after(&group).await {
            tokio::time::sleep(wait).await;
        }
        let _ = admin.session().stage_unrecorded_for_test(&group).await;
    }
    let admin = admin.reopen();
    assert!(
        !roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "premise: the roster is the staged commit's",
    );
    admin
        .session()
        .queue_removal_intent_for_test(&group, &[leaver.pubkey_hex()])
        .await
        .expect("the removal is queued");

    admin
        .session()
        .retire_every_queued_change_for_test(&group)
        .await;

    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let kept: Vec<String> = rusqlite::Connection::open(
        admin
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .prepare("SELECT member FROM removal_targets WHERE gone_epoch IS NULL")
    .expect("the table exists")
    .query_map([], |row| row.get::<_, Vec<u8>>(0).map(hex::encode))
    .expect("read")
    .collect::<Result<_, _>>()
    .expect("read");
    assert!(
        queue_len(&admin, &group).await == 0
            && admin.session().peek_change_notes(&group) == [ChangeNote::QueuedRemovalDropped]
            && kept == [leaver.pubkey_hex()],
        "a removal of a member a staged commit omits was retired as moot, or its member was \
         not kept",
    );
}

/// A queued change is told to its circle BEFORE it is retired, and one whose
/// note cannot be written stays queued: the note is the only other trace of
/// what the user asked for. The line that says so names nothing.
#[tokio::test]
async fn a_queued_change_whose_circle_cannot_be_told_stays_queued() {
    let GatedFour {
        alice,
        bob,
        carol,
        group,
        first,
        ..
    } = a_circle_of_four_whose_changes_queue(Second::RemovesCarol).await;
    let queued = bob
        .session()
        .remove_members(&group, &[carol.pubkey_hex()])
        .await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    drop(alice);
    bob.session()
        .process_event_settled_for_test(&first)
        .await
        .expect("bob follows alice");
    assert!(!roster(&bob, &group).await.contains(&carol.pubkey_hex()));

    // The next process cannot write notes.
    let CircleMember { circle, keys, dir } = bob;
    drop(Arc::try_unwrap(circle).unwrap_or_else(|_| panic!("still shared")));
    let notes = Arc::new(BalkyNotes::default());
    notes.refusing.store(true, Ordering::SeqCst);
    let session =
        SessionManager::new_unencrypted_with_notes(dir.path(), &keys, Some(notes.clone()))
            .expect("the store reopens");
    let count = || async {
        session
            .queued_intent_count_for_test(&group)
            .await
            .expect("the queue")
    };
    assert_eq!(count().await, 1, "premise: the moot removal is queued");

    let lines = capture_haven_log(async {
        session
            .retire_unmakeable_queued_changes_for_test(&group)
            .await;
    })
    .await;
    assert_eq!(
        count().await,
        1,
        "a queued change was retired though its circle could not be told",
    );
    assert!(lines.iter().any(|line| line
        .message
        .contains("stays queued: its circle could not be told")));
    assert_no_needles(
        &lines,
        &[&hex::encode(group.as_slice()), &carol.pubkey_hex(), CANARY],
    );

    notes.refusing.store(false, Ordering::SeqCst);
    session
        .retire_unmakeable_queued_changes_for_test(&group)
        .await;
    assert_eq!(count().await, 0);
    assert_eq!(
        haven_core::nostr::mls::CommitNotes::peek(notes.as_ref(), &group),
        [ChangeNote::QueuedChangeDropped]
    );
}

/// A change this device queued while it was an admin is retired once it no
/// longer is: the engine would refuse to make it now, and make it the day
/// the device is an admin again.
#[tokio::test]
async fn a_change_queued_by_an_admin_is_retired_once_they_are_no_longer_one() {
    let GatedFour {
        alice,
        bob,
        group,
        first,
        ..
    } = a_circle_of_four_whose_changes_queue(Second::DemotesBob).await;
    let clock = Clock::at(0);
    let queued = bob
        .session()
        .update_relays(&group, vec![ONE.to_string(), THREE.to_string()])
        .await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    // Alice has taken Bob out of the admins; Bob learns of it.
    drop(alice);
    bob.session()
        .process_event_settled_for_test(&first)
        .await
        .expect("bob follows alice");
    assert!(
        !bob.session()
            .admin_pubkeys(&group)
            .await
            .expect("admins")
            .contains(&bob.keys.public_key().to_bytes()),
        "premise: bob is no longer an admin",
    );
    assert_eq!(queue_len(&bob, &group).await, 1, "premise: still queued");

    // A store that cannot take the retirement: the change stays queued, and
    // nothing says it was dropped while it was not.
    let (db, key) = db_of(&bob);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true).expect("arm");
    let needles = [hex::encode(group.as_slice()), bob.pubkey_hex()];
    let needles = [needles[0].as_str(), needles[1].as_str(), CANARY];
    let lines = capture_haven_log(async {
        let _ = bob
            .session()
            .advance_for_drive(&group, clock.now_ms())
            .await;
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
        .expect("disarm");
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "a queued change that can no longer be made was not retired",
        )),
        &needles,
    );
    assert_eq!(queue_len(&bob, &group).await, 1);
    assert!(
        !bob.session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedChangeDropped),
        "a change still queued was said to have been dropped",
    );

    let mut advanced = None;
    let lines = capture_haven_log(async {
        advanced = Some(
            bob.session()
                .advance_for_drive(&group, clock.now_ms())
                .await,
        );
    })
    .await;
    let advanced = advanced
        .expect("ran")
        .unwrap_or_else(|_| panic!("the advance runs"));
    assert!(advanced.fanouts.is_empty());
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "a queued change that can no longer be made was retired unmade",
        )),
        &needles,
    );
    assert_eq!(queue_len(&bob, &group).await, 0);
    assert!(
        bob.session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::QueuedChangeDropped),
        "a change its author may no longer make was left queued, or retired untold",
    );
}

/// The retirement of a released change's queued copy can fail. It is said in
/// the log, the record stands, and the hold that confirms the commit retires
/// the copy: nothing is left to be made a second time.
#[tokio::test]
async fn a_released_changes_copy_that_could_not_be_retired_is_said_and_retired_at_the_confirm() {
    let Gated {
        bob,
        group,
        opens_the_gate,
        ..
    } = a_circle_whose_changes_queue().await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let queued = bob
        .session()
        .update_relays(&group, vec![ONE.to_string(), THREE.to_string()])
        .await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("the gate opens");

    let (db, key) = db_of(&bob);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true).expect("arm");
    let mut released = None;
    let lines = capture_haven_log(async {
        released = Some(
            bob.session()
                .advance_for_drive(&group, clock.now_ms())
                .await,
        );
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
        .expect("disarm");
    let released = released
        .expect("ran")
        .unwrap_or_else(|_| panic!("the advance runs"));
    let [id] = <[FanoutId; 1]>::try_from(released.fanouts)
        .unwrap_or_else(|_| panic!("the queued change was not released under one record"));
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "the queued copy of a recorded change was not retired",
        )),
        &[&hex::encode(group.as_slice()), &bob.pubkey_hex(), CANARY],
    );
    assert_eq!(
        queue_len(&bob, &group).await,
        1,
        "premise: the copy is left"
    );

    // A new session has no link from the commit to its queued copy.
    let bob = bob.reopen();
    let applied = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the record is driven"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    assert_eq!(queue_len(&bob, &group).await, 0);
}

/// A change released from the queue and recorded, whose queued copy is still
/// there when the process dies — the hold was cut between the two writes —
/// is confirmed after the restart without the engine's own link to it. The
/// confirm's hold retires the copy: left queued, a relay change would be made
/// a second time at the next full advance.
#[tokio::test]
async fn a_recorded_changes_queued_copy_left_by_a_kill_is_retired_when_it_is_confirmed() {
    let Gated {
        bob,
        group,
        opens_the_gate,
        ..
    } = a_circle_whose_changes_queue().await;
    let transport = answering(&[(ONE, &[Answer::Accepted]), (TWO, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let queued = bob
        .session()
        .update_relays(&group, vec![ONE.to_string(), THREE.to_string()])
        .await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("the gate opens");
    let released = bob
        .session()
        .advance_convergence(&group)
        .await
        .expect("the user-facing advance");
    // Recorded through the seam that leaves the queued copy in place: what a
    // kill between the record's write and the retirement leaves.
    let [id] = <[FanoutId; 1]>::try_from(
        bob.session()
            .stage_commits_for_test(released, clock.now_ms())
            .await
            .fanouts,
    )
    .unwrap_or_else(|_| panic!("premise: released and recorded"));
    assert_eq!(
        queue_len(&bob, &group).await,
        1,
        "premise: the copy is left"
    );

    let bob = bob.reopen();
    let applied = drive_one(&bob.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the restored record is driven"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    assert_eq!(
        queue_len(&bob, &group).await,
        0,
        "the queued copy of a confirmed change was left to be made a second time",
    );
    let again = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    assert!(again.fanouts.is_empty() && staged_ref(&bob, &group).await.is_none());
}

/// The engine can fail a full advance AFTER it staged a queued change: the
/// result is dropped with the error, and the commit is left staged with no
/// handle and no record. Nothing has left the device, so it is rolled back
/// in that hold; the change stays queued and is released, under its record,
/// by the next advance.
#[tokio::test]
async fn a_commit_a_failed_advance_left_staged_is_rolled_back_in_its_hold() {
    let Gated {
        bob,
        group,
        opens_the_gate,
        ..
    } = a_circle_whose_changes_queue().await;
    let clock = Clock::at(0);
    let queued = bob
        .session()
        .update_relays(&group, vec![ONE.to_string(), THREE.to_string()])
        .await;
    assert!(queued.is_ok_and(|effects| !effects.queued.is_empty()));
    bob.session()
        .process_event_settled_for_test(&opens_the_gate)
        .await
        .expect("the gate opens");

    bob.session().fail_next_full_advance_for_test();
    let mut advanced = None;
    let lines = capture_haven_log(async {
        advanced = Some(
            bob.session()
                .advance_for_drive(&group, clock.now_ms())
                .await,
        );
    })
    .await;
    let advanced = advanced
        .expect("ran")
        .unwrap_or_else(|_| panic!("the failed advance stopped its circle"));
    assert!(advanced.fanouts.is_empty());
    assert!(
        staged_ref(&bob, &group).await.is_none()
            && !bob.session().staged_without_fanout_for_test(&group).await,
        "a commit a failed advance staged was left staged with no record",
    );
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "a commit a failed advance left staged is rolled back unsent",
        )),
        &[&hex::encode(group.as_slice()), &bob.pubkey_hex(), CANARY],
    );
    assert!(can_send(&bob, &group).await);

    // Still queued, and made by the next advance.
    assert_eq!(queue_len(&bob, &group).await, 1);
    let released = bob
        .session()
        .advance_for_drive(&group, clock.now_ms())
        .await
        .expect("the advance runs");
    assert_eq!(released.fanouts.len(), 1);
}

// ── Repair ───────────────────────────────────────────────────────────────────

/// The epoch-rotation repair is one call. Its 24-hour rate limit is spent
/// when the rotation is APPLIED — in the call that staged it, or by a later
/// drive of the same session — and never by a rotation every relay refused.
#[tokio::test]
async fn a_repair_rotation_spends_its_rate_limit_when_it_is_applied_and_only_then() {
    for (answers, first, last) in [
        (&[Answer::Accepted][..], EvolutionStatus::Confirmed, true),
        (
            &[Answer::Silent, Answer::Accepted][..],
            EvolutionStatus::Unresolved,
            true,
        ),
        (&[Answer::Refused][..], EvolutionStatus::RolledBack, false),
    ] {
        let fx = setup_circle(2, &[ONE]).await;
        let (admin, _others, group) = split(fx);
        let ngid = nostr_group_id(&admin, &group).await;
        let transport = answering(&[(ONE, answers)]);
        let outbox = Outbox::default();
        let clock = Clock::ahead_of_the_device(3 * DAY_MS);
        let changes = through(&transport, &outbox, &clock);

        let RepairOutcome::Rotated(outcome) = changes
            .repair_rotation(&admin.circle, &group)
            .await
            .expect("the repair runs")
        else {
            panic!("premise: every gate is open, and the rotation is staged");
        };
        assert_eq!(outcome.status, first);
        let spent = || {
            admin
                .circle
                .circle_rotation_state(&ngid)
                .expect("rotation state")
                .last_rotation_at_ms
                .is_some()
        };
        assert_eq!(
            spent(),
            first == EvolutionStatus::Confirmed,
            "the rate limit was spent by a rotation that is not applied, or not by one that is",
        );

        clock.set(HOUR_MS);
        let _ = changes.resume(&admin.circle).await;
        assert_eq!(
            spent(),
            last,
            "a rotation applied by a later drive of its session spent no rate limit, \
             or one every relay refused spent it",
        );
    }
}

/// A rotation is applied whether or not its rate limit could be recorded.
/// The failure is said in the log, naming no circle, and costs the limit
/// alone: the circle may be repaired again sooner than a day.
#[tokio::test]
async fn a_rate_limit_that_could_not_be_recorded_is_said_and_the_rotation_stands() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let ngid = nostr_group_id(&admin, &group).await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::ahead_of_the_device(3 * DAY_MS);
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        admin
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("open the circle store")
    .execute_batch(
        "CREATE TRIGGER test_health_fault BEFORE INSERT ON circle_health
         BEGIN SELECT RAISE(ABORT, 'injected'); END;",
    )
    .expect("arm the fault");

    let mut repaired = None;
    let lines = Box::pin(capture_haven_log(async {
        repaired = Some(
            through(&transport, &outbox, &clock)
                .repair_rotation(&admin.circle, &group)
                .await,
        );
    }))
    .await;
    let RepairOutcome::Rotated(outcome) = repaired.expect("ran").expect("the repair runs") else {
        panic!("premise: every gate is open, and the rotation is staged");
    };
    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "recording the rate limit failed")),
        &[
            &hex::encode(group.as_slice()),
            &hex::encode(ngid),
            &admin.pubkey_hex(),
            CANARY,
        ],
    );
    assert!(
        admin
            .circle
            .circle_rotation_state(&ngid)
            .expect("rotation state")
            .last_rotation_at_ms
            .is_none(),
        "premise: the limit was not recorded",
    );
}

/// A repair rotation applied only after a restart charges no rate limit: the
/// link between the rotation and its circle's limit is the session's own.
/// Accepted and pinned — the user may repair again within the day.
#[tokio::test]
async fn a_repair_rotation_confirmed_after_a_restart_charges_no_rate_limit() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let ngid = nostr_group_id(&admin, &group).await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::ahead_of_the_device(3 * DAY_MS);
    let RepairOutcome::Rotated(outcome) = through(&transport, &outbox, &clock)
        .repair_rotation(&admin.circle, &group)
        .await
        .expect("the repair runs")
    else {
        panic!("premise: the rotation is staged");
    };
    assert_eq!(outcome.status, EvolutionStatus::Unresolved);

    let admin = admin.reopen();
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let resumed = through(&transport, &outbox, &clock)
        .resume(&admin.circle)
        .await;
    assert!(!resumed.errored);
    assert!(
        staged_ref(&admin, &group).await.is_none(),
        "premise: applied by the resume",
    );
    assert!(
        admin
            .circle
            .circle_rotation_state(&ngid)
            .expect("rotation state")
            .last_rotation_at_ms
            .is_none(),
        "a rotation confirmed after a restart charged the rate limit: the pinned \
         residual has changed — update the tracker",
    );
}

/// A gate that declines the repair says which, and nothing is staged: here
/// the circle's epoch moved, by the first repair itself, less than a day ago.
/// Any member may repair, so admin rank is no longer a gate.
#[tokio::test]
async fn a_repair_a_gate_declines_stages_nothing() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::ahead_of_the_device(3 * DAY_MS);
    let changes = through(&transport, &outbox, &clock);
    let RepairOutcome::Rotated(first) = changes
        .repair_rotation(&admin.circle, &group)
        .await
        .expect("the repair runs")
    else {
        panic!("premise: every gate is open, and the rotation is staged");
    };
    assert_eq!(first.status, EvolutionStatus::Confirmed, "premise");
    let rows = rows_of(&admin, &group).await;
    transport.calls();

    // The stamps the gates read are the device's own clock's.
    let soon = Clock::ahead_of_the_device(HOUR_MS);
    let outcome = through(&transport, &outbox, &soon)
        .repair_rotation(&admin.circle, &group)
        .await
        .expect("the repair runs");
    assert!(
        matches!(
            outcome,
            RepairOutcome::Skipped(SkipReason::RecentEpochChange)
        ),
        "a repair an hour after the epoch moved was not declined as such: {outcome:?}",
    );
    assert!(
        rows_of(&admin, &group).await == rows && transport.calls().is_empty(),
        "a declined repair staged or sent something",
    );
}

// ── Add, and its Welcomes ────────────────────────────────────────────────────

/// The Welcomes the engine holds for delivery. A circle's founding Welcomes
/// are among them, so a test reads what an invite added to `before`.
async fn owed_welcomes(member: &CircleMember) -> Vec<Vec<u8>> {
    member
        .session()
        .outstanding_welcome_ids_for_test()
        .await
        .expect("welcomes")
        .iter()
        .map(|id| id.as_slice().to_vec())
        .collect()
}

/// A Welcome is handed over by its commit's confirm and by nothing else: in
/// the call that applies the invite it goes out once, to its invitee's own
/// relays and nowhere else, and only when the invitee is already a member on
/// this device; a relay's acknowledgement of it completes its delivery.
#[tokio::test]
async fn a_welcome_is_released_only_by_its_commits_confirm() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.watch(&admin, &group, &invitee);
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (1, 1));
    assert!(outcome.notes.is_empty());
    let handed = outbox.handed();
    let [(welcome, relays)] = <[_; 1]>::try_from(handed)
        .unwrap_or_else(|_| panic!("exactly the one Welcome is sent, once"));
    assert_eq!(welcome.kind.as_u16(), 1059);
    assert_eq!(recipient_of(&welcome), Some(invitee.pubkey_hex()));
    assert_eq!(
        relays,
        [INBOX],
        "a Welcome was sent somewhere other than its invitee's own relays",
    );
    assert!(
        !outbox.sent_a_welcome_early(),
        "a Welcome left the device before its invite was applied",
    );
    assert_eq!(
        owed_welcomes(&admin).await,
        before,
        "an acknowledged Welcome was left outstanding",
    );
}

/// An invite still awaiting relays sends no Welcome and makes none
/// deliverable. The drive that confirms it — later, in the same session —
/// sends it then; and once it is delivered the record lets go of it and ends.
#[tokio::test]
async fn a_swallowed_ok_add_stays_awaiting_and_its_welcome_goes_out_after_the_ack() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    outbox.watch(&admin, &group, &invitee);
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let outcome = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(outcome.status, EvolutionStatus::Unresolved);
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (0, 1));
    assert!(
        outbox.handed().is_empty(),
        "a Welcome was sent before its commit was acknowledged",
    );
    assert_eq!(
        owed_welcomes(&admin).await,
        before,
        "a Welcome was made deliverable before its commit was applied",
    );
    let (id, row) = the_row(&admin, &group).await;
    assert_eq!(row.held_welcomes, 1);
    assert_eq!(
        admin
            .session()
            .welcome_route_for_test(&group, &invitee.pubkey_hex()),
        Some(vec![INBOX.to_string()]),
        "the route an invite resolved was not kept beside its staged commit",
    );

    // The acknowledgement arrives on a later drive.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let resumed = changes.resume(&admin.circle).await;
    assert_eq!(resumed.welcomes_sent, 1);
    let handed = outbox.handed();
    let [(welcome, relays)] = <[_; 1]>::try_from(handed)
        .unwrap_or_else(|_| panic!("exactly the one Welcome is sent, once"));
    assert_eq!(
        welcome.id.to_bytes().as_slice(),
        row.welcome_ids[0].as_slice()
    );
    assert_eq!(relays, [INBOX]);
    assert!(!outbox.sent_a_welcome_early());
    assert!(roster(&admin, &group).await.contains(&invitee.pubkey_hex()));
    assert_eq!(owed_welcomes(&admin).await, before);
    assert!(admin
        .session()
        .welcome_route_for_test(&group, &invitee.pubkey_hex())
        .is_none());

    // Delivered: the record lets go of it at its next drive, and ends.
    clock.set(2 * HOUR_MS);
    let again = changes.resume(&admin.circle).await;
    assert_eq!(again.welcomes_sent, 0);
    assert!(
        outbox.handed().is_empty(),
        "a delivered Welcome was sent again"
    );
    assert!(probe(&admin, &id).await.is_none());
}

/// An invite every relay refused is undone, and its Welcome is never sent —
/// not in the call, and not by any drive after it.
#[tokio::test]
async fn a_rolled_back_add_never_delivers_its_welcome() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Refused])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let outcome = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(outcome.status, EvolutionStatus::RolledBack);
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (0, 1));
    assert!(
        admin
            .session()
            .welcome_route_for_test(&group, &invitee.pubkey_hex())
            .is_none(),
        "the route kept for an undone invite's Welcome outlived it",
    );
    for hours in [1, 30] {
        clock.set(hours * HOUR_MS);
        let _ = changes.resume(&admin.circle).await;
    }
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "the Welcome of an invite that was undone was sent",
    );
    assert_eq!(
        owed_welcomes(&admin).await,
        before,
        "the Welcome of an invite that was undone was made deliverable",
    );
    assert!(!roster(&admin, &group).await.contains(&invitee.pubkey_hex()));
}

/// A Welcome's delivery is completed only when a relay of its invitee's
/// inbox acknowledged that exact event. Of two invitees, the one whose relay
/// did not acknowledge stays outstanding, is reported unsent and keeps its
/// delivery record; it is sent again on its relay's schedule, byte for byte,
/// until that relay acknowledges it — and never once it has.
#[tokio::test]
async fn a_welcome_is_marked_delivered_only_on_an_inbox_relay_ok_for_that_event() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (_first, first_package) = an_invitee().await;
    let (second, second_package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&second.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let outcome = changes
        .add_members(&admin.circle, &group, &[first_package, second_package])
        .await
        .expect("the invite is accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert_eq!(
        (outcome.welcomes_sent, outcome.welcomes_total),
        (1, 2),
        "the Welcomes sent were not reported truthfully",
    );
    let handed = outbox.handed();
    assert_eq!(welcomes(&handed).len(), 2, "premise: both were handed out");
    let unacknowledged = welcomes(&handed)
        .into_iter()
        .find(|(event, _)| recipient_of(event) == Some(second.pubkey_hex()))
        .expect("the second invitee's Welcome")
        .0
        .id
        .to_bytes()
        .to_vec();
    let owed: Vec<Vec<u8>> = owed_welcomes(&admin)
        .await
        .into_iter()
        .filter(|id| !before.contains(id))
        .collect();
    assert_eq!(
        owed,
        std::slice::from_ref(&unacknowledged),
        "a Welcome no relay acknowledged was completed, or an acknowledged one was not",
    );
    let unacknowledged = MessageId::new(unacknowledged);
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed],
        "the circle was not told a Welcome is still owed",
    );
    assert!(
        admin
            .session()
            .welcome_record_for_test(&unacknowledged)
            .await
            .is_some_and(|(_, relays, attempts)| relays == [INBOX] && attempts == [1]),
        "a Welcome no relay acknowledged has no record, or one owed elsewhere",
    );
    let first_sent = welcomes(&handed)
        .into_iter()
        .find(|(event, _)| recipient_of(event) == Some(second.pubkey_hex()))
        .map(|(event, _)| nostr::JsonUtil::as_json(event))
        .expect("the second invitee's Welcome");

    // Not again before its relay is due, then on its schedule until an inbox
    // relay acknowledges it — the exact bytes, every time — and never after.
    clock.set(10 * SECOND_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 0);
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome was sent before it was due"
    );
    clock.set(HOUR_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 0);
    let again = outbox.handed();
    assert!(
        welcomes(&again)
            .iter()
            .all(
                |(event, relays)| nostr::JsonUtil::as_json(event) == first_sent
                    && relays == &[INBOX]
            )
            && welcomes(&again).len() == 1,
        "a Welcome owed was not sent again on its schedule, or not byte for byte",
    );
    outbox.acknowledge_everything();
    clock.set(3 * HOUR_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 1);
    assert_eq!(owed_welcomes(&admin).await, before);
    assert!(admin
        .session()
        .welcome_record_for_test(&unacknowledged)
        .await
        .is_none());
    assert!(
        admin.session().peek_change_notes(&group).is_empty(),
        "the note that a Welcome is owed outlived its delivery",
    );
    outbox.handed();
    for hours in [4, 30] {
        clock.set(hours * HOUR_MS);
        assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 0);
    }
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a delivered Welcome was sent again",
    );
}

/// Where a Welcome goes is kept per circle. One person invited to two of the
/// user's circles, both invites still awaiting their relays, is sent both
/// Welcomes when the invites are applied — neither takes the other's route.
#[tokio::test]
async fn one_person_invited_to_two_circles_is_sent_a_welcome_for_each() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, first) = split(fx);
    let relays = vec![TWO.to_string()];
    let second = admin
        .circle
        .create_circle(
            &admin.keys,
            Vec::new(),
            &haven_core::circle::CircleConfig::new("Second").with_relays(relays.clone()),
        )
        .await
        .expect("a second circle")
        .circle
        .mls_group_id;
    let invitee = CircleMember::new();
    let inbox = vec![INBOX.to_string()];
    let transport = answering(&[(ONE, &[Answer::Silent]), (TWO, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    for group in [&first, &second] {
        let package = MemberKeyPackage {
            key_package_event: create_key_package_event(invitee.session(), &invitee.keys, &inbox)
                .await,
            inbox_relays: inbox.clone(),
            nip65_relays: Vec::new(),
        };
        let outcome = changes
            .add_members(&admin.circle, group, &[package])
            .await
            .expect("the invite is accepted");
        assert_eq!(outcome.status, EvolutionStatus::Unresolved);
    }
    assert!(outbox.handed().is_empty(), "premise: nothing sent yet");

    transport.answer(ONE, [Answer::Accepted]);
    transport.answer(TWO, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let resumed = changes.resume(&admin.circle).await;

    assert_eq!(
        resumed.welcomes_sent, 2,
        "an invite to one circle took the route of the invite to another",
    );
    let handed = outbox.handed();
    assert_eq!(welcomes(&handed).len(), 2);
    assert!(welcomes(&handed).iter().all(|(event, relays)| {
        recipient_of(event) == Some(invitee.pubkey_hex()) && relays == &inbox
    }));
}

/// The Welcome a confirm hands over is delivered from its own durable
/// record, so no kill loses it: a process killed while the invite awaits its
/// relays, or after the commit was applied and before an inbox relay
/// acknowledged the Welcome, delivers it after the restart — the exact bytes
/// it was sent as before, to its invitee's inbox — and the engine counts it
/// delivered; one killed after the delivery sends nothing again.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_welcome_survives_a_kill_at_every_point_of_its_hand_over() {
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum KilledWhen {
        AwaitingRelays,
        AppliedAndUndelivered,
        Delivered,
    }
    for killed in [
        KilledWhen::AwaitingRelays,
        KilledWhen::AppliedAndUndelivered,
        KilledWhen::Delivered,
    ] {
        let fx = setup_circle(2, &[ONE]).await;
        let (admin, _others, group) = split(fx);
        let before = owed_welcomes(&admin).await;
        let (invitee, package) = an_invitee().await;
        let transport = answering(&[(
            ONE,
            if killed == KilledWhen::AwaitingRelays {
                &[Answer::Silent, Answer::Accepted][..]
            } else {
                &[Answer::Accepted][..]
            },
        )]);
        let outbox = Outbox::default();
        if killed != KilledWhen::Delivered {
            outbox.withhold_welcome_to(&invitee.pubkey_hex());
        }
        let clock = Clock::at(0);
        let outcome = through(&transport, &outbox, &clock)
            .add_members(&admin.circle, &group, &[package])
            .await
            .expect("accepted");
        assert_eq!(
            (outcome.status, outcome.welcomes_sent),
            match killed {
                KilledWhen::AwaitingRelays => (EvolutionStatus::Unresolved, 0),
                KilledWhen::AppliedAndUndelivered => (EvolutionStatus::Confirmed, 0),
                KilledWhen::Delivered => (EvolutionStatus::Confirmed, 1),
            },
            "premise ({killed:?})",
        );
        let first = welcomes(&outbox.handed())
            .first()
            .map(|(event, _)| nostr::JsonUtil::as_json(event));

        let admin = admin.reopen();
        outbox.acknowledge_everything();
        clock.set(HOUR_MS);
        let resumed = through(&transport, &outbox, &clock)
            .resume(&admin.circle)
            .await;
        let handed = outbox.handed();
        let sent = welcomes(&handed);
        if killed == KilledWhen::Delivered {
            assert!(
                resumed.welcomes_sent == 0 && sent.is_empty(),
                "a delivered Welcome was sent again after a restart",
            );
            assert_eq!(owed_welcomes(&admin).await, before);
            continue;
        }
        let [(welcome, relays)] = <[_; 1]>::try_from(sent).unwrap_or_else(|_| {
            panic!("a Welcome still owed was not delivered after a restart ({killed:?})")
        });
        assert!(
            resumed.welcomes_sent == 1
                && recipient_of(welcome) == Some(invitee.pubkey_hex())
                && relays == &[INBOX]
                && first.is_none_or(|first| first == nostr::JsonUtil::as_json(welcome)),
            "the Welcome delivered after a restart is not the one owed, to its invitee's inbox, \
             byte for byte as it was first sent ({killed:?})",
        );
        assert_eq!(
            owed_welcomes(&admin).await,
            before,
            "a Welcome delivered after a restart was left outstanding ({killed:?})",
        );
    }
}

/// Before every send the commit's state is read again. While branch
/// selection has set it aside for now, its Welcome is not sent and its record
/// is kept: taken up again, the commit still owes it, and it is delivered.
/// Set aside for good, it is never sent, it ends as failed, and its record
/// ends.
#[tokio::test]
async fn a_welcome_waits_while_its_commit_is_set_aside_and_is_never_sent_once_that_is_final() {
    for taken_up_again in [true, false] {
        let fx = setup_circle(2, &[ONE]).await;
        let (admin, _others, group) = split(fx);
        let before = owed_welcomes(&admin).await;
        let (invitee, package) = an_invitee().await;
        let transport = answering(&[(ONE, &[Answer::Accepted])]);
        let outbox = Outbox::default();
        outbox.withhold_welcome_to(&invitee.pubkey_hex());
        let clock = Clock::at(0);
        let _ = through(&transport, &outbox, &clock)
            .add_members(&admin.circle, &group, &[package])
            .await
            .expect("accepted");
        outbox.handed();
        let [welcome] = <[Vec<u8>; 1]>::try_from(
            owed_welcomes(&admin)
                .await
                .into_iter()
                .filter(|id| !before.contains(id))
                .collect::<Vec<_>>(),
        )
        .unwrap_or_else(|_| panic!("premise: the invite's one Welcome is owed"));
        let welcome = MessageId::new(welcome);
        let (commit, _, _) = admin
            .session()
            .welcome_record_for_test(&welcome)
            .await
            .expect("premise: the Welcome has its delivery record");
        outbox.acknowledge_everything();

        let admin = restate(admin, commit.as_slice(), MessageState::ConvergenceDeferred);
        clock.set(HOUR_MS);
        let waiting = through(&transport, &outbox, &clock)
            .resume(&admin.circle)
            .await;
        assert!(
            waiting.welcomes_sent == 0
                && welcomes(&outbox.handed()).is_empty()
                && admin
                    .session()
                    .welcome_record_for_test(&welcome)
                    .await
                    .is_some(),
            "a Welcome was sent for a commit that is set aside, or its record was let go of",
        );

        let admin = restate(
            admin,
            commit.as_slice(),
            if taken_up_again {
                MessageState::Processed
            } else {
                MessageState::EpochInvalidated
            },
        );
        clock.set(2 * HOUR_MS);
        let settled = through(&transport, &outbox, &clock)
            .resume(&admin.circle)
            .await;
        let sent = welcomes(&outbox.handed()).len();
        if taken_up_again {
            assert!(
                settled.welcomes_sent == 1 && sent == 1 && owed_welcomes(&admin).await == before,
                "a commit taken up again did not deliver its Welcome",
            );
        } else {
            assert!(
                settled.welcomes_sent == 0
                    && sent == 0
                    && admin
                        .session()
                        .welcome_record_for_test(&welcome)
                        .await
                        .is_none()
                    && admin
                        .session()
                        .stored_message_record_for_test(&welcome)
                        .await
                        .expect("read")
                        .is_some_and(|record| record.state == MessageState::Failed),
                "the Welcome of a commit lost for good was sent, kept, or not ended as failed",
            );
        }
    }
}

/// The commit's state is read once more immediately before each Welcome
/// leaves. Of two Welcomes one drive handed over, the second is not sent when
/// a convergence pass has set their commit aside in between — and it is not
/// let go of either.
#[tokio::test]
async fn a_welcome_handed_over_is_not_sent_once_its_commit_has_been_set_aside() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (_first, first_package) = an_invitee().await;
    let (_second, second_package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let source = admin.session().epoch(&group).await.expect("epoch");
    outbox.set_aside_on_first_hand(&admin, &group, source);
    let clock = Clock::at(0);

    let outcome = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[first_package, second_package])
        .await
        .expect("accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (1, 2));
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        1,
        "a Welcome was sent for a commit no longer this device's canonical one",
    );
    let [kept] = <[Vec<u8>; 1]>::try_from(
        owed_welcomes(&admin)
            .await
            .into_iter()
            .filter(|id| !before.contains(id))
            .collect::<Vec<_>>(),
    )
    .unwrap_or_else(|_| panic!("one Welcome is still owed"));
    let (commit, _, _) = admin
        .session()
        .welcome_record_for_test(&MessageId::new(kept))
        .await
        .expect("the Welcome not sent keeps its record");
    assert_eq!(
        admin
            .session()
            .stored_message_record_for_test(&commit)
            .await
            .expect("read")
            .map(|record| record.state),
        Some(MessageState::ConvergenceDeferred),
        "premise: the commit was set aside between the two sends",
    );
}

/// A frozen Welcome the engine neither holds for delivery nor has seen
/// delivered, under a commit that is this device's canonical one, leaves its
/// invitee on the roster with no way in. That is said, typed and durably —
/// the invitee must be invited again — and never only logged.
///
/// No path of the pinned engine reaches that state for an invite. An invite's
/// commit carries a path — MDK stages it with `add_members`, and Haven's
/// invite grants no admin — and a path-bearing commit of this device's own is
/// applied only through a confirm, which promotes its Welcomes in the same
/// transaction (`cgka-engine/src/publish.rs` 163-177); both are held by
/// `an_invites_commit_is_applied_only_through_a_confirm_at_this_pin`. (A
/// commit WITHOUT a path — a relay change, a hand-over, a step-down — can be
/// applied with no confirm, and carries no Welcome.) The state is written
/// into a closed store here, so that an engine which one day reaches it by
/// another path is not met with silence.
#[tokio::test]
async fn an_invite_applied_with_no_deliverable_welcome_says_a_reinvite_is_owed() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let outcome = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("accepted");
    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    outbox.handed();
    let welcome = owed_welcomes(&admin)
        .await
        .into_iter()
        .last()
        .expect("premise: the Welcome is owed");

    let admin = restate(admin, &welcome, MessageState::Failed);
    clock.set(HOUR_MS);
    let resumed = through(&transport, &outbox, &clock)
        .resume(&admin.circle)
        .await;

    assert!(!resumed.errored);
    assert!(welcomes(&outbox.handed()).is_empty());
    assert!(roster(&admin, &group).await.contains(&invitee.pubkey_hex()));
    assert_eq!(
        admin.session().take_change_notes(&group),
        [ChangeNote::ReinviteOwed],
        "an invitee locked out of the circle they were added to was not reported",
    );
    assert!(
        admin
            .session()
            .welcome_record_for_test(&MessageId::new(welcome))
            .await
            .is_none(),
        "the record of a Welcome nobody can deliver was kept",
    );
}

/// The same for the other shape such a Welcome can be found in: its stored
/// row exactly as the invite's staging wrote it — a Welcome that is not yet
/// deliverable — under a commit that has since been applied. The engine
/// promotes that row in the confirm's own transaction, so this state too is
/// written into a closed store; found, it is said, never met with silence
/// and never sent as it stands.
#[tokio::test]
async fn an_invite_applied_with_its_welcome_still_as_staged_says_a_reinvite_is_owed() {
    use cgka_traits::storage::MessageStorage as _;

    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let outcome = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("accepted");
    assert_eq!(outcome.status, EvolutionStatus::Unresolved);
    let (id, row) = the_row(&admin, &group).await;
    let welcome = row.welcome_ids[0].clone();

    // The Welcome's row while its invite is only staged.
    let mut as_staged = None;
    let admin = with_closed_store(admin, |store| {
        as_staged = Some(
            store
                .get_message(&welcome)
                .expect("the staged Welcome's row"),
        );
    });
    let as_staged = as_staged.expect("read");

    // The relay takes the commit: applied, the Welcome promoted and owed.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let applied = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the record is driven"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    assert!(roster(&admin, &group).await.contains(&invitee.pubkey_hex()));
    outbox.handed();

    // And the row put back as the staging had left it.
    let admin = with_closed_store(admin, |store| {
        let promoted = store.get_message(&welcome).expect("the promoted row");
        assert!(
            promoted.payload != as_staged.payload,
            "premise: a staged Welcome's row differs from a deliverable one's",
        );
        store.put_message(&as_staged).expect("put back as staged");
    });
    clock.set(2 * HOUR_MS);
    let resumed = through(&transport, &outbox, &clock)
        .resume(&admin.circle)
        .await;

    assert!(!resumed.errored);
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome that was never made deliverable was sent",
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ReinviteOwed],
        "an invitee locked out of the circle they were added to was not reported",
    );
    assert!(probe(&admin, &id).await.is_none());
}

/// Whether `wrap` is a Welcome to `invitee` as the Nostr binding says one is
/// (`transports/nostr.md` 57-79 and "Welcome delivery"), read from the bytes
/// alone: a kind-1059 wrap signed by a one-time key, not the inviter, with
/// exactly one `p`, its invitee's; inside, a signed kind-13 seal with no
/// tags; inside that, a kind-444 rumor with no `sig` field and the seal's
/// pubkey, exactly one `e` naming the `KeyPackage` event and nothing else,
/// exactly one `relays` tag with the circle's relays, and an `mls_welcome`
/// `MLSMessage` in base64 as its content; the wrap's and the seal's
/// `created_at` tweaked no more than NIP-59's two days into the past.
fn welcome_shape(
    wrap: &nostr::Event,
    invitee: &nostr::Keys,
    sender: &nostr::PublicKey,
    key_package: nostr::EventId,
    relays: &[&str],
) -> Result<(), &'static str> {
    use base64::Engine as _;
    use nostr::nips::nip44;

    fn tags_named<'a>(tags: &'a [serde_json::Value], name: &str) -> Vec<&'a [serde_json::Value]> {
        tags.iter()
            .filter_map(serde_json::Value::as_array)
            .filter(|tag| tag.first().and_then(serde_json::Value::as_str) == Some(name))
            .map(Vec::as_slice)
            .collect()
    }

    if wrap.kind.as_u16() != 1059 || wrap.verify().is_err() {
        return Err("not a signed gift wrap");
    }
    // NIP-59: the wrap is signed by a one-time key, and both it and the seal
    // carry a `created_at` tweaked up to two days into the past.
    if &wrap.pubkey == sender {
        return Err("the wrap is signed by the inviter, not a one-time key");
    }
    let now = nostr::Timestamp::now().as_secs();
    let tweaked = |created_at: nostr::Timestamp| {
        let at = created_at.as_secs();
        at <= now + 60 && at + 2 * 86_400 + 60 >= now
    };
    if !tweaked(wrap.created_at) {
        return Err("the wrap's created_at is outside NIP-59's window");
    }
    let wrap_json: serde_json::Value =
        serde_json::from_str(&nostr::JsonUtil::as_json(wrap)).map_err(|_| "unreadable wrap")?;
    let p = tags_named(wrap_json["tags"].as_array().ok_or("no tags")?, "p");
    let invitee_hex = serde_json::Value::from(invitee.public_key().to_hex());
    if !matches!(p.as_slice(), [[_, value]] if *value == invitee_hex) {
        return Err("the wrap does not carry exactly one p, its invitee's");
    }
    let seal = nip44::decrypt(invitee.secret_key(), &wrap.pubkey, &wrap.content)
        .map_err(|_| "the wrap does not open")?;
    let seal = <nostr::Event as nostr::JsonUtil>::from_json(seal).map_err(|_| "no seal")?;
    if seal.kind.as_u16() != 13 || seal.verify().is_err() {
        return Err("not a signed seal");
    }
    if !seal.tags.is_empty() {
        return Err("the seal carries tags");
    }
    if !tweaked(seal.created_at) {
        return Err("the seal's created_at is outside NIP-59's window");
    }
    let rumor = nip44::decrypt(invitee.secret_key(), &seal.pubkey, &seal.content)
        .map_err(|_| "the seal does not open")?;
    let rumor: serde_json::Value = serde_json::from_str(&rumor).map_err(|_| "no rumor")?;
    if rumor.get("sig").is_some() {
        return Err("the rumor carries a sig");
    }
    if rumor["kind"] != 444 {
        return Err("the rumor is not a kind-444 Welcome");
    }
    if rumor["pubkey"] != seal.pubkey.to_hex() {
        return Err("the rumor's pubkey is not the seal's");
    }
    let tags = rumor["tags"].as_array().ok_or("the rumor has no tags")?;
    let e = tags_named(tags, "e");
    let key_package_hex = serde_json::Value::from(key_package.to_hex());
    if !matches!(e.as_slice(), [[_, value]] if *value == key_package_hex) {
        return Err("the rumor does not carry exactly one e, the KeyPackage's");
    }
    let named = tags_named(tags, "relays");
    let [listed] = named.as_slice() else {
        return Err("the rumor does not carry exactly one relays tag");
    };
    if listed[1..]
        != relays
            .iter()
            .map(|r| serde_json::Value::from(*r))
            .collect::<Vec<_>>()[..]
    {
        return Err("the relays tag does not list the circle's relays");
    }
    let content = base64::engine::general_purpose::STANDARD
        .decode(rumor["content"].as_str().ok_or("no content")?)
        .map_err(|_| "the content is not base64")?;
    // `MLSMessage`: version mls10 (1), then wire format mls_welcome (3).
    if content.get(..4) != Some(&[0, 1, 0, 3][..]) {
        return Err("the content is not an mls_welcome MLSMessage");
    }
    Ok(())
}

/// The Welcome an invite sends is, byte for byte on the wire, what the
/// Marmot Nostr binding says it is (Rules 3 and 16: the rumor is unsigned
/// and is never handed to `verify()`). The checker is shown to refuse a wrap
/// that breaks a cardinality row, so a pass is not a checker that accepts
/// anything.
#[tokio::test]
async fn welcome_rumor_unsigned_one_e_one_relays_and_wrap_one_p() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (invitee, package) = an_invitee().await;
    let key_package = package.key_package_event.id;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let outcome = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    let handed = outbox.handed();
    let [(wrap, _)] =
        <[_; 1]>::try_from(welcomes(&handed)).unwrap_or_else(|_| panic!("the one Welcome is sent"));

    assert_eq!(
        welcome_shape(
            wrap,
            &invitee.keys,
            &admin.keys.public_key(),
            key_package,
            &[ONE]
        ),
        Ok(())
    );

    let two_e = nostr::EventBuilder::new(nostr::Kind::Custom(444), "AAEAAw==")
        .tags([
            nostr::Tag::event(key_package),
            nostr::Tag::event(key_package),
            nostr::Tag::custom(nostr::TagKind::custom("relays"), [ONE]),
        ])
        .build(admin.keys.public_key());
    let forged = nostr::EventBuilder::gift_wrap(&admin.keys, &invitee.keys.public_key(), two_e, [])
        .await
        .expect("a wrap");
    assert_eq!(
        welcome_shape(
            &forged,
            &invitee.keys,
            &admin.keys.public_key(),
            key_package,
            &[ONE]
        ),
        Err("the rumor does not carry exactly one e, the KeyPackage's"),
    );
    let one_e = nostr::EventBuilder::new(nostr::Kind::Custom(444), "AAEAAw==")
        .tags([
            nostr::Tag::event(key_package),
            nostr::Tag::custom(nostr::TagKind::custom("relays"), [ONE]),
        ])
        .build(admin.keys.public_key());
    let two_p = nostr::EventBuilder::gift_wrap(
        &admin.keys,
        &invitee.keys.public_key(),
        one_e,
        [nostr::Tag::public_key(admin.keys.public_key())],
    )
    .await
    .expect("a wrap");
    assert_eq!(
        welcome_shape(
            &two_p,
            &invitee.keys,
            &admin.keys.public_key(),
            key_package,
            &[ONE]
        ),
        Err("the wrap does not carry exactly one p, its invitee's"),
    );

    // A founding Welcome, sent from its record, is shaped the same.
    let founder = CircleMember::new();
    let (invitee, package) = an_invitee().await;
    let key_package = package.key_package_event.id;
    let outbox = Outbox::default();
    let _ = through(&transport, &outbox, &clock)
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![package],
            &founding_config(),
        )
        .await
        .expect("the circle is created");
    let handed = outbox.handed();
    let [(wrap, _)] = <[_; 1]>::try_from(welcomes(&handed))
        .unwrap_or_else(|_| panic!("the founding Welcome is sent"));
    assert_eq!(
        welcome_shape(
            wrap,
            &invitee.keys,
            &founder.keys.public_key(),
            key_package,
            &[ONE]
        ),
        Ok(())
    );
}

/// Founding Welcomes outstanding with no delivery record — made before any
/// were kept — are never sent from here: on no drive, at no hour, and they
/// are left as they are. Haven keeps no route for them and resolves none
/// (`docs/MDK_UPSTREAM_TRACKER.md` T-WELCOME-OUTBOX).
#[tokio::test]
async fn a_founding_welcome_with_no_record_is_never_sent() {
    let founder = CircleMember::new();
    let (_one, first) = an_invitee().await;
    let (_two, second) = an_invitee().await;
    let created = founder
        .circle
        .create_circle(&founder.keys, vec![first, second], &founding_config())
        .await
        .expect("the circle is created");
    let group = created.circle.mls_group_id;
    for record in founder
        .session()
        .welcome_record_ids_for_test(&group)
        .await
        .expect("read")
    {
        founder
            .session()
            .delete_welcome_record_for_test(&record)
            .await;
    }
    let founding = owed_welcomes(&founder).await;
    assert_eq!(
        founding.len(),
        2,
        "premise: the founding Welcomes are outstanding"
    );
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    for at in [0, 30 * SECOND_MS, HOUR_MS, DAY_MS - SECOND_MS, 2 * DAY_MS] {
        clock.set(at);
        assert_eq!(changes.resume(&founder.circle).await.welcomes_sent, 0);
    }

    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a founding Welcome with no record was sent",
    );
    assert_eq!(owed_welcomes(&founder).await, founding);
}

fn founding_config() -> haven_core::circle::CircleConfig {
    haven_core::circle::CircleConfig::new("Founded").with_relays(vec![ONE.to_string()])
}

/// The one delivery record of `founder`'s circle `group`.
async fn the_record(
    founder: &CircleMember,
    group: &GroupId,
) -> (MessageId, haven_core::nostr::mls::types::WelcomeRecordProbe) {
    let ids = founder
        .session()
        .welcome_record_ids_for_test(group)
        .await
        .expect("read");
    let [id] = <[_; 1]>::try_from(ids).unwrap_or_else(|_| panic!("exactly one record"));
    let probe = founder
        .session()
        .welcome_record_probe_for_test(&id)
        .await
        .expect("the record is read");
    (id, probe)
}

/// A circle's founding Welcome is a delivery obligation of its own from the
/// moment the circle exists: the create returns with a record for it — its
/// circle, no commit, its invitee's inbox, the engine's exact bytes, one
/// acknowledgement to complete it, a bound a day off — and nothing sent.
#[tokio::test]
async fn a_founding_welcome_is_recorded_before_create_returns_and_before_any_send() {
    let founder = CircleMember::new();
    let (invitee, package) = an_invitee().await;
    let before = u64::try_from(chrono::Utc::now().timestamp()).expect("after 1970");
    let created = founder
        .circle
        .create_circle(&founder.keys, vec![package], &founding_config())
        .await
        .expect("the circle is created");
    let group = created.circle.mls_group_id.clone();

    let (_, record) = the_record(&founder, &group).await;
    assert!(
        record.commit.is_none(),
        "a founding Welcome's record names a commit"
    );
    assert_eq!(record.group.as_ref(), Some(&group));
    assert_eq!(record.recipient, invitee.pubkey_hex());
    assert_eq!(
        record.endpoints,
        [INBOX],
        "owed somewhere other than the invitee's inbox"
    );
    assert_eq!(
        record.attempts,
        [0],
        "a founding Welcome was sent before the create returned"
    );
    assert_eq!(record.required_acks, 1);
    let bound = record.bounded_until_secs.expect("a bound");
    assert!(
        bound > before && bound <= before + 24 * 3_600 + 60,
        "a founding Welcome is driven for longer than a day",
    );
    let [returned] =
        <[_; 1]>::try_from(created.welcome_events).unwrap_or_else(|_| panic!("one Welcome"));
    assert_eq!(
        <nostr::Event as nostr::JsonUtil>::from_json(&record.payload).expect("an event"),
        returned.event,
        "the record does not hold the engine's exact Welcome",
    );
    assert_eq!(
        founder.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed]
    );
}

/// A founding Welcome is sent from its record, the exact stored bytes, to
/// its invitee's inbox alone — at once, then on its relay's schedule — and
/// is completed only by an inbox relay's acknowledgement of that event,
/// which ends its record; it is never sent again after.
#[tokio::test]
async fn a_founding_welcome_is_sent_from_its_record_until_an_inbox_relay_takes_it() {
    let founder = CircleMember::new();
    let (invitee, package) = an_invitee().await;
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let created = changes
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![package],
            &founding_config(),
        )
        .await
        .expect("the circle is created");
    assert_eq!((created.welcomes_sent, created.welcomes_total), (0, 1));
    assert_eq!(created.unsent_recipients, [invitee.pubkey_hex()]);
    let group = created.circle.mls_group_id.clone();
    let (id, record) = the_record(&founder, &group).await;
    let handed = outbox.handed();
    let [(first, relays)] = <[_; 1]>::try_from(welcomes(&handed))
        .unwrap_or_else(|_| panic!("the founding Welcome is sent once at the create"));
    assert_eq!(relays, &[INBOX]);
    assert_eq!(recipient_of(first), Some(invitee.pubkey_hex()));
    let sent = nostr::JsonUtil::as_json(first);
    assert_eq!(
        sent.as_bytes(),
        record.payload,
        "not the record's exact bytes"
    );

    clock.set(29 * SECOND_MS);
    let _ = changes.resume(&founder.circle).await;
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "sent before its relay was due"
    );
    clock.set(30 * SECOND_MS);
    let _ = changes.resume(&founder.circle).await;
    let again = outbox.handed();
    assert!(
        matches!(welcomes(&again).as_slice(), [(event, relays)]
            if nostr::JsonUtil::as_json(event) == sent && relays == &[INBOX]),
        "a founding Welcome owed was not sent again on its schedule, byte for byte",
    );
    assert!(owed_welcomes(&founder)
        .await
        .contains(&id.as_slice().to_vec()));

    outbox.acknowledge_everything();
    clock.set(90 * SECOND_MS);
    assert_eq!(changes.resume(&founder.circle).await.welcomes_sent, 1);
    assert!(
        founder
            .session()
            .welcome_record_probe_for_test(&id)
            .await
            .is_none()
            && !owed_welcomes(&founder)
                .await
                .contains(&id.as_slice().to_vec()),
        "an acknowledged founding Welcome was left owed",
    );
    assert!(founder.session().peek_change_notes(&group).is_empty());
    outbox.handed();
    clock.set(DAY_MS);
    let _ = changes.resume(&founder.circle).await;
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a delivered founding Welcome was sent again"
    );
    assert!(
        transport.calls().is_empty(),
        "a Welcome went through the commit transport"
    );
}

/// A founding Welcome no relay took before the process ended is sent by the
/// first foreground drive of the next — never by a drive that only
/// finishes.
#[tokio::test]
async fn a_founding_welcome_survives_a_restart_and_is_sent_by_the_next_foreground_drive() {
    let founder = CircleMember::new();
    let (invitee, package) = an_invitee().await;
    let created = founder
        .circle
        .create_circle(&founder.keys, vec![package], &founding_config())
        .await
        .expect("the circle is created");
    let group = created.circle.mls_group_id.clone();
    let [returned] =
        <[_; 1]>::try_from(created.welcome_events).unwrap_or_else(|_| panic!("one Welcome"));
    let founder = founder.reopen();
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let _ = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: &clock,
        deadline_ms: None,
        mode: &DriveMode::FinishOnly,
    }
    .resume(&founder.circle)
    .await;
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a drive that only finishes sent a founding Welcome",
    );

    assert_eq!(
        through(&transport, &outbox, &clock)
            .resume(&founder.circle)
            .await
            .welcomes_sent,
        1
    );
    let handed = outbox.handed();
    assert!(
        matches!(welcomes(&handed).as_slice(), [(event, relays)]
            if *event == returned.event && relays == &[INBOX]
                && recipient_of(event) == Some(invitee.pubkey_hex())),
        "the founding Welcome was not sent from its record after the restart",
    );
    assert!(founder
        .session()
        .welcome_record_ids_for_test(&group)
        .await
        .expect("read")
        .is_empty());
}

/// A founding Welcome whose record cannot be written fails the create
/// before anything is sent: the founded group is forgotten with every record
/// written for it, and no circle is left.
#[tokio::test]
async fn a_founding_welcome_record_that_cannot_be_written_undoes_the_create() {
    let founder = CircleMember::new();
    let (_one, first) = an_invitee().await;
    let (_two, second) = an_invitee().await;
    let (db, key) = db_of(&founder);
    haven_core::nostr::mls::storage::set_welcome_record_write_fault_for_test(&db, &key, 1, true)
        .expect("arm");
    let outbox = Outbox::default();
    let created = through(&ScriptedFanout::default(), &outbox, &Clock::at(0))
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![first, second],
            &founding_config(),
        )
        .await;
    haven_core::nostr::mls::storage::set_welcome_record_write_fault_for_test(&db, &key, 0, false)
        .expect("disarm");

    assert!(
        created.is_err(),
        "a create whose Welcome had no record succeeded"
    );
    assert!(
        outbox.handed().is_empty(),
        "something was sent for an undone create"
    );
    assert!(
        founder.circle.get_circles().await.expect("read").is_empty()
            && founder
                .session()
                .live_group_ids()
                .await
                .expect("read")
                .is_empty(),
        "an undone create left a circle or its group",
    );
}

/// A driven create reports as sent only the founding Welcomes an inbox
/// relay acknowledged, and names the invitees whose Welcome is still owed.
#[tokio::test]
async fn create_circle_driven_counts_only_acknowledged_welcomes() {
    let founder = CircleMember::new();
    let (_taken, taken) = an_invitee().await;
    let (unanswered, refused) = an_invitee().await;
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&unanswered.pubkey_hex());
    let clock = Clock::at(0);

    let created = through(&transport, &outbox, &clock)
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![taken, refused],
            &founding_config(),
        )
        .await
        .expect("the circle is created");

    assert_eq!((created.welcomes_sent, created.welcomes_total), (1, 2));
    assert_eq!(created.unsent_recipients, [unanswered.pubkey_hex()]);
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        2,
        "premise: both were sent"
    );
}

/// A founding Welcome that the device's own drive delivered beside the
/// create — the live plane's, which sends owed Welcomes from the same
/// records — is reported sent by the create: it was delivered, once, and
/// "0 of 2 sent" would tell the user otherwise.
#[tokio::test]
async fn a_founding_welcome_another_drive_delivers_under_the_create_counts_as_sent() {
    let founder = CircleMember::new();
    let (_first, first) = an_invitee().await;
    let (_second, second) = an_invitee().await;
    let outbox = Outbox::default();
    *outbox.drives_beside.lock().expect("outbox") = Some(Arc::clone(&founder.circle));

    let created = through(&ScriptedFanout::default(), &outbox, &Clock::at(0))
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![first, second],
            &founding_config(),
        )
        .await
        .expect("the circle is created");

    assert!(
        created.unsent_recipients.is_empty(),
        "premise: both Welcomes were delivered",
    );
    assert_eq!(
        (created.welcomes_sent, created.welcomes_total),
        (2, 2),
        "a Welcome another drive delivered under the create was reported unsent",
    );
}

/// A full mode which, at its first read made with the engine free once
/// `circle` holds a Welcome record that is not among `before`, does what may
/// happen between a change writing its Welcomes' records and this call's
/// drive listing them: the live plane's own drive runs, beside the call,
/// over `beside`; or the clock moves on.
struct OnFreshWelcomeRecord<'a> {
    circle: Arc<CircleManager>,
    before: Vec<MessageId>,
    beside: Outbox,
    advances: Option<(&'a Clock, u64)>,
    fired: AtomicBool,
}

impl<'a> OnFreshWelcomeRecord<'a> {
    fn drives_beside(member: &CircleMember, before: Vec<MessageId>, beside: Outbox) -> Self {
        Self {
            circle: Arc::clone(&member.circle),
            before,
            beside,
            advances: None,
            fired: AtomicBool::new(false),
        }
    }

    fn advances(member: &CircleMember, before: Vec<MessageId>, clock: &'a Clock, to: u64) -> Self {
        Self {
            advances: Some((clock, to)),
            ..Self::drives_beside(member, before, Outbox::default())
        }
    }

    fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }

    async fn fire_once_fresh(&self) {
        let mut fresh = false;
        for circle in self.circle.get_circles().await.expect("read") {
            fresh |= self
                .circle
                .session()
                .welcome_record_ids_for_test(&circle.circle.mls_group_id)
                .await
                .expect("read")
                .iter()
                .any(|id| !self.before.contains(id));
        }
        if !fresh || self.fired.swap(true, Ordering::SeqCst) {
            return;
        }
        match self.advances {
            Some((clock, to)) => clock.set(to),
            None => {
                let _ = through(&ScriptedFanout::default(), &self.beside, &Clock::at(0))
                    .resume(&self.circle)
                    .await;
            }
        }
    }
}

impl ModeSource for OnFreshWelcomeRecord<'_> {
    fn mode(&self) -> DriveMode {
        if !self.fired() && !self.circle.session().session_is_held_for_test() {
            tokio::task::block_in_place(|| {
                tokio::runtime::Handle::current().block_on(self.fire_once_fresh());
            });
        }
        DriveMode::Full
    }
}

const fn moded<'a>(
    fanout: &'a ScriptedFanout,
    publisher: &'a Outbox,
    clock: &'a Clock,
    mode: &'a OnFreshWelcomeRecord<'a>,
) -> Publishing<'a, ScriptedFanout> {
    Publishing {
        fanout,
        publisher,
        clock,
        deadline_ms: None,
        mode,
    }
}

/// A founding Welcome the live plane's drive delivered, and whose record it
/// ended, before the create's own drive listed the records is reported sent:
/// a relay took it, and "0 of 2 sent" would send the user to a remedy for
/// nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_founding_welcome_another_drive_delivers_before_the_create_lists_it_counts_as_sent() {
    let founder = CircleMember::new();
    let (_first, first) = an_invitee().await;
    let (_second, second) = an_invitee().await;
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let mode = OnFreshWelcomeRecord::drives_beside(&founder, Vec::new(), Outbox::default());

    let created = moded(&ScriptedFanout::default(), &outbox, &clock, &mode)
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![first, second],
            &founding_config(),
        )
        .await
        .expect("the circle is created");

    assert!(
        mode.fired() && welcomes(&outbox.handed()).is_empty(),
        "premise: the other drive took both records before the create listed them",
    );
    assert!(
        created.unsent_recipients.is_empty(),
        "premise: both Welcomes were delivered",
    );
    assert_eq!(
        (created.welcomes_sent, created.welcomes_total),
        (2, 2),
        "a Welcome delivered before the create listed its record was reported unsent",
    );
}

/// A founding Welcome no relay acknowledged is reported unsent and names its
/// invitee, though another drive took up its record beside the create and
/// delivered the other.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_founding_welcome_never_acknowledged_counts_as_unsent_and_names_its_invitee() {
    let founder = CircleMember::new();
    let (_taken, taken) = an_invitee().await;
    let (unanswered, refused) = an_invitee().await;
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&unanswered.pubkey_hex());
    let beside = Outbox::default();
    beside.withhold_welcome_to(&unanswered.pubkey_hex());
    let clock = Clock::at(0);
    let mode = OnFreshWelcomeRecord::drives_beside(&founder, Vec::new(), beside);

    let created = moded(&ScriptedFanout::default(), &outbox, &clock, &mode)
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![taken, refused],
            &founding_config(),
        )
        .await
        .expect("the circle is created");

    assert!(mode.fired(), "premise: the other drive ran");
    assert_eq!((created.welcomes_sent, created.welcomes_total), (1, 2));
    assert_eq!(created.unsent_recipients, [unanswered.pubkey_hex()]);
}

/// An invite's Welcome the live plane's drive delivered, and whose record it
/// ended, before the invite's own drive listed the records is reported sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invites_welcome_another_drive_delivers_before_the_invite_lists_it_counts_as_sent() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = admin
        .session()
        .welcome_record_ids_for_test(&group)
        .await
        .expect("read");
    let (_invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let mode = OnFreshWelcomeRecord::drives_beside(&admin, before, Outbox::default());

    let outcome = moded(&transport, &outbox, &clock, &mode)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert!(
        mode.fired() && welcomes(&outbox.handed()).is_empty(),
        "premise: the other drive took the record before the invite listed it",
    );
    assert_eq!(
        (outcome.welcomes_sent, outcome.welcomes_total),
        (1, 1),
        "a Welcome delivered before the invite listed its record was reported unsent",
    );
}

/// An invite counts only its own Welcomes: an earlier invite's, owed and
/// delivered by this call's drive, is not this one's, which no relay took.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invite_does_not_count_an_earlier_invites_welcome_as_its_own() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (earlier, first) = an_invitee().await;
    let (later, second) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted, Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&earlier.pubkey_hex());
    let clock = Clock::at(0);
    let invited = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[first])
        .await
        .expect("the first invite is accepted");
    assert_eq!(
        (invited.status, invited.welcomes_sent),
        (EvolutionStatus::Confirmed, 0)
    );
    let before = admin
        .session()
        .welcome_record_ids_for_test(&group)
        .await
        .expect("read");
    outbox.handed();
    outbox.acknowledge_everything();
    outbox.withhold_welcome_to(&later.pubkey_hex());
    // The earlier Welcome's relay falls due again while the second invite is
    // driven, after its commit is applied.
    let mode = OnFreshWelcomeRecord::advances(&admin, before.clone(), &clock, 30 * SECOND_MS);

    let outcome = moded(&transport, &outbox, &clock, &mode)
        .add_members(&admin.circle, &group, &[second])
        .await
        .expect("the second invite is accepted");

    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    let handed = outbox.handed();
    assert!(
        mode.fired()
            && welcomes(&handed)
                .iter()
                .any(|(event, _)| recipient_of(event) == Some(earlier.pubkey_hex()))
            && admin
                .session()
                .welcome_record_ids_for_test(&group)
                .await
                .expect("read")
                .iter()
                .all(|id| !before.contains(id)),
        "premise: the earlier invite's Welcome was delivered during the call",
    );
    assert_eq!(
        (outcome.welcomes_sent, outcome.welcomes_total),
        (0, 1),
        "an earlier invite's Welcome was counted as this one's",
    );
}

/// `admin` removes `member_hex` from `group`, a relay acknowledging it.
async fn removes(admin: &CircleMember, group: &GroupId, member_hex: &str, clock: &Clock) {
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let removed = through(&transport, &outbox, clock)
        .remove_members(&admin.circle, group, &[member_hex.to_owned()])
        .await
        .expect("the removal is made");
    assert_eq!(
        removed.status,
        EvolutionStatus::Confirmed,
        "premise: applied"
    );
}

/// A Welcome still owed stops being sent once its invitee is no longer on
/// the roster — its record ends, the engine no longer counts it
/// outstanding, and the circle's note that one is owed goes with the last —
/// and once the circle is disbanded, whose settle ends its records; for a
/// founding Welcome and an invite's alike. (A
/// `KeyPackage` past its `not_after` bounds the record, and the bound's own
/// end is `a_welcome_no_relay_takes_for_a_day_is_sent_no_more_and_stays_owed`'s;
/// the fold is `a_welcomes_bound_is_its_key_packages_not_after_when_sooner`.)
#[tokio::test]
async fn the_outbox_stops_for_a_removed_invitee_a_disbanded_group_and_an_expired_key_package() {
    for (founding, stop) in [(true, "removed"), (false, "removed"), (true, "disbanded")] {
        let (admin, group, invitee, outbox) = if founding {
            let founder = CircleMember::new();
            let (invitee, package) = an_invitee().await;
            let outbox = Outbox::default();
            outbox.withhold_welcome_to(&invitee.pubkey_hex());
            let transport = ScriptedFanout::default();
            let created = through(&transport, &outbox, &Clock::at(0))
                .create_circle(
                    &founder.circle,
                    &founder.keys,
                    vec![package],
                    &founding_config(),
                )
                .await
                .expect("the circle is created");
            (founder, created.circle.mls_group_id, invitee, outbox)
        } else {
            let (admin, _others, group) = split(setup_circle(2, &[ONE]).await);
            let (invitee, package) = an_invitee().await;
            let outbox = Outbox::default();
            outbox.withhold_welcome_to(&invitee.pubkey_hex());
            let transport = answering(&[(ONE, &[Answer::Accepted])]);
            let _ = through(&transport, &outbox, &Clock::at(0))
                .add_members(&admin.circle, &group, &[package])
                .await
                .expect("the invite is made");
            (admin, group, invitee, outbox)
        };
        let (welcome, _) = the_record(&admin, &group).await;
        assert_eq!(
            welcomes(&outbox.handed()).len(),
            1,
            "premise: sent once ({stop})"
        );
        let clock = Clock::at(0);
        if stop == "removed" {
            removes(&admin, &group, &invitee.pubkey_hex(), &clock).await;
        } else {
            helpers::drive::disband(&admin, &group).await;
        }

        clock.set(HOUR_MS);
        let resumed = through(&ScriptedFanout::default(), &outbox, &clock)
            .resume(&admin.circle)
            .await;

        assert_eq!(resumed.welcomes_sent, 0);
        assert!(
            welcomes(&outbox.handed()).is_empty(),
            "a Welcome was sent after its circle ended for it ({stop}, founding: {founding})",
        );
        assert!(
            admin
                .session()
                .welcome_record_probe_for_test(&welcome)
                .await
                .is_none(),
            "a Welcome no longer wanted kept its record ({stop}, founding: {founding})",
        );
        // The disband's settle deletes the records itself (MDK
        // `cgka-engine/src/disband.rs` 598-604); a removal's end is Haven's.
        if stop == "removed" {
            assert!(
                !owed_welcomes(&admin)
                    .await
                    .contains(&welcome.as_slice().to_vec()),
                "a Welcome no longer wanted was left owed (founding: {founding})",
            );
            assert!(
                !admin
                    .session()
                    .peek_change_notes(&group)
                    .contains(&ChangeNote::WelcomeOwed),
                "the circle is still told a Welcome is owed (founding: {founding})",
            );
        }
    }
}

/// A circle this device was removed from sends none of its Welcomes: a
/// founding one owed when the removal was applied is ended, never sent.
#[tokio::test]
async fn a_welcome_is_not_sent_for_a_circle_this_device_was_removed_from() {
    let fx = setup_circle(2, &[ONE]).await;
    helpers::stranded::co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let co = others.remove(0);
    let (invitee, package) = an_invitee().await;
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let clock = Clock::at(0);
    let _ = through(&transport, &outbox, &clock)
        .add_members(&co.circle, &group, &[package])
        .await
        .expect("the co-admin invites");
    let invite = nostr::JsonUtil::from_json(
        transport
            .calls()
            .pop()
            .expect("premise: the invite was sent")
            .payload,
    )
    .expect("an event");
    let (welcome, _) = the_record(&co, &group).await;
    assert_eq!(welcomes(&outbox.handed()).len(), 1, "premise: sent once");
    let _ = admin
        .session()
        .process_event_settled_for_test(&invite)
        .await;
    let removal = {
        let transport = answering(&[(ONE, &[Answer::Accepted])]);
        let _ = through(&transport, &Outbox::default(), &clock)
            .remove_members(&admin.circle, &group, &[co.pubkey_hex()])
            .await
            .expect("the co-admin is removed");
        nostr::JsonUtil::from_json(transport.calls().pop().expect("sent").payload)
            .expect("an event")
    };
    let _ = co.session().process_event_settled_for_test(&removal).await;
    assert!(co.session().removed_for_test(&group).await, "premise");

    clock.set(HOUR_MS);
    let _ = through(&ScriptedFanout::default(), &outbox, &clock)
        .resume(&co.circle)
        .await;

    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome of a circle this device was removed from was sent",
    );
    assert!(co
        .session()
        .welcome_record_probe_for_test(&welcome)
        .await
        .is_none());
}

/// A Welcome goes to its invitee's inbox and never to the inviter's own: an
/// inviter whose inbox list holds a relay sends the invitee's Welcome to the
/// invitee's relays alone, and an invitee with no inbox relay is refused at
/// the invite, before anything is staged, rather than sent a Welcome to
/// relays they never read.
#[tokio::test]
async fn welcome_never_sent_to_sender_inbox() {
    const SENDER_INBOX: &str = "wss://sender-inbox.change-canary3d8f.example.com";

    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    admin
        .circle
        .add_user_relay(
            SENDER_INBOX,
            haven_core::circle::relay_prefs::RelayType::Inbox,
        )
        .expect("the inviter's inbox");
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let (_reachable, package) = an_invitee().await;
    let outcome = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(outcome.welcomes_sent, 1);
    assert!(welcomes(&outbox.handed())
        .iter()
        .all(|(_, relays)| relays == &[INBOX]));
    transport.calls();

    let unreachable = CircleMember::new();
    let package = MemberKeyPackage {
        key_package_event: create_key_package_event(
            unreachable.session(),
            &unreachable.keys,
            &[INBOX.to_string()],
        )
        .await,
        inbox_relays: Vec::new(),
        nip65_relays: Vec::new(),
    };
    let roster_before = roster(&admin, &group).await;
    let refused = changes.add_members(&admin.circle, &group, &[package]).await;
    assert!(matches!(
        refused,
        Err(haven_core::circle::CircleError::MissingWelcomeRelays)
    ));
    assert!(
        outbox.handed().is_empty(),
        "something was sent for a refused invite"
    );
    assert!(
        transport.calls().is_empty(),
        "a refused invite staged a commit"
    );
    assert_eq!(roster(&admin, &group).await, roster_before);
    assert!(staged_ref(&admin, &group).await.is_none());
}

/// A Welcome no inbox relay acknowledges is sent on its relay's schedule for
/// a day from its hand-over, and then no more: its record stays, inert, the
/// engine still holds it outstanding, and the circle keeps the note that a
/// Welcome is still owed — the one thing that tells its user to invite
/// again. Once the note was shown the record goes.
#[tokio::test]
async fn a_welcome_no_relay_takes_for_a_day_is_sent_no_more_and_stays_owed() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let outcome = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (0, 1));
    assert_eq!(welcomes(&outbox.handed()).len(), 1);
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed]
    );
    let welcome = owed_welcomes(&admin)
        .await
        .into_iter()
        .find(|id| !before.contains(id))
        .map(MessageId::new)
        .expect("the Welcome is owed");

    clock.set(DAY_MS - SECOND_MS);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        1,
        "a Welcome owed was not sent within its day",
    );
    clock.set(DAY_MS);
    let _ = changes.resume(&admin.circle).await;
    clock.set(2 * DAY_MS);
    let _ = changes.resume(&admin.circle).await;

    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome was sent after its day",
    );
    assert!(admin
        .session()
        .welcome_record_for_test(&welcome)
        .await
        .is_some());
    assert!(owed_welcomes(&admin)
        .await
        .contains(&welcome.as_slice().to_vec()));
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed],
        "the circle was not left told that a Welcome is still owed",
    );
    let shown = admin.session().change_notice(&group);
    assert!(admin.session().acknowledge_change_notice(&group, &shown));
    clock.set(3 * DAY_MS);
    let _ = changes.resume(&admin.circle).await;
    assert!(
        welcomes(&outbox.handed()).is_empty()
            && admin
                .session()
                .welcome_record_for_test(&welcome)
                .await
                .is_none(),
        "an expired Welcome's record outlived its shown note, or was sent",
    );
}

/// A founding Welcome no inbox relay acknowledges is likewise sent on its
/// relay's schedule for a day from the create, and then no more: its record
/// stays, inert, the engine still holds it outstanding, and the founder is
/// left told that a Welcome is still owed.
#[tokio::test]
async fn a_founding_welcome_no_relay_takes_for_a_day_is_sent_no_more_and_stays_owed() {
    let transport = ScriptedFanout::default();
    let founder = CircleMember::new();
    let (invitee, package) = an_invitee().await;
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let created = changes
        .create_circle(
            &founder.circle,
            &founder.keys,
            vec![package],
            &founding_config(),
        )
        .await
        .expect("the circle is created");
    let group = created.circle.mls_group_id;
    let (welcome, _) = the_record(&founder, &group).await;
    assert_eq!(welcomes(&outbox.handed()).len(), 1);
    clock.set(DAY_MS - SECOND_MS);
    let _ = changes.resume(&founder.circle).await;
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        1,
        "a founding Welcome owed was not sent within its day",
    );
    clock.set(DAY_MS);
    let _ = changes.resume(&founder.circle).await;
    clock.set(2 * DAY_MS);
    let _ = changes.resume(&founder.circle).await;
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a founding Welcome was sent after its day",
    );
    assert!(founder
        .session()
        .welcome_record_probe_for_test(&welcome)
        .await
        .is_some());
    assert!(owed_welcomes(&founder)
        .await
        .contains(&welcome.as_slice().to_vec()));
    assert_eq!(
        founder.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed],
        "the founder was not left told that a Welcome is still owed",
    );
}

/// A Welcome staged for one commit is never delivered with another. An
/// invite's Welcome left as its staging wrote it — bound to that invite's
/// commit — while a different commit of the same epoch, here a relay change,
/// is applied is failed by the engine in that confirm (MDK
/// `cgka-engine/src/message_processor/store.rs` 70-113, at this pin), and
/// nothing here sends it: no record, no note, nothing on the wire.
#[tokio::test]
async fn a_welcome_staged_for_another_commit_of_its_epoch_is_failed_by_the_confirm_and_never_sent()
{
    use cgka_traits::storage::MessageStorage as _;

    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (_invitee, package) = an_invitee().await;
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    // Staged and recorded, no relay yet sent it.
    let id = admin
        .circle
        .add_members_staging(&group, &[package], 0)
        .await
        .expect("the invite is staged")
        .commit
        .expect("the invite's commit is recorded");
    let welcome = probe(&admin, &id).await.expect("its row").welcome_ids[0].clone();
    let mut as_staged = None;
    let admin = with_closed_store(admin, |store| {
        as_staged = Some(
            store
                .get_message(&welcome)
                .expect("the staged Welcome's row"),
        );
    });
    let as_staged = as_staged.expect("read");

    // Every relay refuses the invite: undone, its Welcome failed with it.
    transport.answer(ONE, [Answer::Refused]);
    clock.set(HOUR_MS);
    let undone = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the record is driven"));
    assert_eq!(undone.status, FanoutStatus::RolledBack);
    // And the Welcome's row put back as the staging wrote it, at the epoch
    // the next commit is staged from.
    let admin = with_closed_store(admin, |store| {
        assert_eq!(
            store.get_message(&welcome).expect("the row").state,
            MessageState::Failed,
            "premise: the undone invite's Welcome failed with it",
        );
        store.put_message(&as_staged).expect("put back as staged");
    });
    let admin = with_closed_store(admin, |store| {
        assert_eq!(
            store.get_message(&welcome).expect("the row"),
            as_staged,
            "premise: an open alone did not end the staged Welcome",
        );
    });

    transport.answer(ONE, [Answer::Accepted]);
    clock.set(2 * HOUR_MS);
    let changed = through(&transport, &outbox, &clock)
        .update_relays(&admin.circle, &group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("the relay change is accepted");
    assert_eq!(changed.status, EvolutionStatus::Confirmed);
    for hours in [3, 30] {
        clock.set(hours * HOUR_MS);
        let _ = through(&transport, &outbox, &clock)
            .resume(&admin.circle)
            .await;
    }

    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome staged for another commit was sent",
    );
    assert!(admin
        .session()
        .welcome_record_for_test(&welcome)
        .await
        .is_none());
    assert!(!admin
        .session()
        .peek_change_notes(&group)
        .contains(&ChangeNote::WelcomeOwed));
    let _admin = with_closed_store(admin, |store| {
        assert_eq!(
            store.get_message(&welcome).expect("the row").state,
            MessageState::Failed,
            "the engine did not fail a Welcome staged for another commit of its epoch",
        );
    });
}

/// The Welcome owed to `invitee` among those `admin` holds outstanding.
async fn owed_to(admin: &CircleMember, before: &[Vec<u8>]) -> MessageId {
    owed_welcomes(admin)
        .await
        .into_iter()
        .find(|id| !before.contains(id))
        .map(MessageId::new)
        .expect("the Welcome is owed")
}

/// A Welcome that reached its day unsent keeps the circle's note that a
/// Welcome is owed, whatever becomes of another: a second invitee's Welcome
/// delivered after the first expired does not take the note away. Once the
/// note was shown, the expired record goes.
#[tokio::test]
async fn an_expired_welcome_keeps_its_note_when_another_is_delivered() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (first, first_package) = an_invitee().await;
    let (second, second_package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&first.pubkey_hex());
    outbox.withhold_welcome_to(&second.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .add_members(&admin.circle, &group, &[first_package])
        .await
        .expect("the first invite is accepted");
    let expiring = owed_to(&admin, &before).await;
    clock.set(12 * HOUR_MS);
    transport.answer(ONE, [Answer::Accepted]);
    let _ = changes
        .add_members(&admin.circle, &group, &[second_package])
        .await
        .expect("the second invite is accepted");
    outbox.handed();

    clock.set(DAY_MS);
    let _ = changes.resume(&admin.circle).await;
    assert!(
        admin
            .session()
            .welcome_record_for_test(&expiring)
            .await
            .is_some()
            && admin.session().peek_change_notes(&group) == [ChangeNote::WelcomeOwed],
        "premise: the first Welcome reached its day, kept, and the circle told",
    );
    outbox.acknowledge_everything();
    clock.set(DAY_MS + 2 * HOUR_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 1);
    assert!(
        welcomes(&outbox.handed())
            .iter()
            .all(|(event, _)| recipient_of(event) == Some(second.pubkey_hex())),
        "a Welcome that reached its day was sent again",
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed],
        "another Welcome's delivery took away the note of one still owed",
    );

    let shown = admin.session().change_notice(&group);
    assert!(admin.session().acknowledge_change_notice(&group, &shown));
    clock.set(DAY_MS + 3 * HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    assert!(
        admin
            .session()
            .welcome_record_for_test(&expiring)
            .await
            .is_none(),
        "an expired record outlived the note it was kept for",
    );
    assert!(admin.session().peek_change_notes(&group).is_empty());
}

/// A hand-over stopped part-way — the second Welcome's record cannot be
/// written — keeps the circle's note that the first, whose record was
/// written, is owed: the note is said with the record, not at the end of the
/// pass. The next pass hands over the rest.
#[tokio::test]
async fn a_welcome_handed_over_before_its_pass_stopped_keeps_its_note() {
    use haven_core::nostr::mls::storage::set_welcome_record_write_fault_for_test;
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (first, first_package) = an_invitee().await;
    let (second, second_package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&first.pubkey_hex());
    outbox.withhold_welcome_to(&second.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let (db, key) = helpers::stranded::mls_db(admin.dir.path());
    set_welcome_record_write_fault_for_test(&db, &key, 1, true).expect("arm");
    let _ = changes
        .add_members(&admin.circle, &group, &[first_package, second_package])
        .await;
    set_welcome_record_write_fault_for_test(&db, &key, 1, false).expect("disarm");
    let mut recorded = 0;
    for welcome in owed_welcomes(&admin).await {
        if admin
            .session()
            .welcome_record_for_test(&MessageId::new(welcome))
            .await
            .is_some()
        {
            recorded += 1;
        }
    }
    assert_eq!(
        recorded, 1,
        "premise: the pass stopped after one Welcome's record"
    );
    assert!(
        admin
            .session()
            .peek_change_notes(&group)
            .contains(&ChangeNote::WelcomeOwed),
        "a Welcome handed over before its pass stopped was not said to be owed",
    );
    let _ = changes.resume(&admin.circle).await;
    let mut recorded = 0;
    for welcome in owed_welcomes(&admin).await {
        if admin
            .session()
            .welcome_record_for_test(&MessageId::new(welcome))
            .await
            .is_some()
        {
            recorded += 1;
        }
    }
    assert_eq!(recorded, 2, "the next pass did not hand over the rest");
}

/// A Welcome whose record another drive ended while it was being sent is
/// not brought back by the answer: the record stays ended.
#[tokio::test]
async fn a_welcome_record_ended_under_its_send_is_not_brought_back() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    outbox.handed();
    let welcome = owed_to(&admin, &before).await;
    assert!(
        admin
            .session()
            .welcome_record_for_test(&welcome)
            .await
            .is_some(),
        "premise"
    );

    *outbox.ends_record.lock().expect("outbox") =
        Some((Arc::clone(&admin.circle), welcome.clone()));
    clock.set(2 * HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        1,
        "premise: the Welcome was sent"
    );
    assert!(
        admin
            .session()
            .welcome_record_for_test(&welcome)
            .await
            .is_none(),
        "an answer brought back a record another drive had ended",
    );
}

/// An acknowledgement that is stored and whose completion is not — the
/// engine's write refused — is completed by the next drive without a send.
#[tokio::test]
async fn a_stored_acknowledgement_is_completed_without_a_send() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (_invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    *outbox.refuses_marks.lock().expect("outbox") = Some(db_of(&admin));
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let outcome = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    let (db, key) = db_of(&admin);
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert_eq!(
        outcome.welcomes_sent, 0,
        "premise: the delivery was not marked"
    );
    let welcome = owed_to(&admin, &before).await;
    assert!(
        admin
            .session()
            .welcome_record_for_test(&welcome)
            .await
            .is_some_and(|(_, _, attempts)| attempts == [1]),
        "premise: the acknowledgement is stored on the record",
    );
    outbox.handed();

    clock.set(HOUR_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 1);
    assert!(
        welcomes(&outbox.handed()).is_empty()
            && owed_welcomes(&admin).await == before
            && admin
                .session()
                .welcome_record_for_test(&welcome)
                .await
                .is_none(),
        "a stored acknowledgement was sent again, or its Welcome left outstanding",
    );
}

/// The commit is read again before each relay after the first: a Welcome
/// whose commit is set aside while its first relay answers is not sent to
/// its second.
#[tokio::test]
async fn a_welcome_is_not_sent_to_its_next_relay_once_its_commit_is_set_aside() {
    const INBOX_TWO: &str = "wss://inbox-two.change-canary3d8f.example.com";

    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let invitee = CircleMember::new();
    let inbox = vec![INBOX.to_string(), INBOX_TWO.to_string()];
    let package = MemberKeyPackage {
        key_package_event: create_key_package_event(invitee.session(), &invitee.keys, &inbox).await,
        inbox_relays: inbox,
        nip65_relays: Vec::new(),
    };
    let epoch = admin
        .session()
        .epoch(&group)
        .await
        .expect("the circle's epoch");
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    outbox.set_aside_on_first_hand(&admin, &group, epoch);
    let clock = Clock::at(0);
    let _ = through(&transport, &outbox, &clock)
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    let handed = outbox.handed();
    assert_eq!(
        welcomes(&handed)
            .iter()
            .map(|(_, relays)| relays.clone())
            .collect::<Vec<_>>(),
        [vec![INBOX.to_string()]],
        "a Welcome went to its next relay after its commit was set aside",
    );
}

/// The engine refusing a Welcome it owes for a reason that can pass — its
/// group not live — is waited out, never taken for "undeliverable": no
/// re-invite is said and the record stays; once the engine answers, the
/// Welcome goes.
#[tokio::test]
async fn a_welcome_the_engine_cannot_answer_for_now_is_waited_for() {
    use haven_core::nostr::mls::StoreFault;

    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let before = owed_welcomes(&admin).await;
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    outbox.handed();
    let welcome = owed_to(&admin, &before).await;

    admin
        .session()
        .fail_store_for_test(StoreFault::SentWelcome, true);
    clock.set(HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    admin
        .session()
        .fail_store_for_test(StoreFault::SentWelcome, false);
    assert!(
        welcomes(&outbox.handed()).is_empty()
            && admin
                .session()
                .welcome_record_for_test(&welcome)
                .await
                .is_some()
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ReinviteOwed),
        "a Welcome the engine could not answer for was taken as undeliverable",
    );
    outbox.acknowledge_everything();
    clock.set(2 * HOUR_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 1);
}

/// A route the circle store cannot read is not a missing one: the confirm's
/// hand-over leaves the Welcome in its commit's record — no re-invite said,
/// nothing released — and the next drive that reads it hands it over.
#[tokio::test]
async fn a_route_the_store_cannot_read_holds_the_welcome_for_the_next_drive() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    let (id, _) = the_row(&admin, &group).await;
    let rename = |from: &str, to: &str| {
        haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
        rusqlite::Connection::open(
            admin
                .dir
                .path()
                .join(haven_core::circle::CIRCLES_DB_FILENAME),
        )
        .expect("the circle store opens")
        .execute_batch(&format!("ALTER TABLE {from} RENAME TO {to}"))
        .expect("renamed");
    };
    rename("welcome_routes", "welcome_routes_away");
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    assert!(
        welcomes(&outbox.handed()).is_empty()
            && probe(&admin, &id)
                .await
                .is_some_and(|row| row.held_welcomes == 1)
            && !admin
                .session()
                .peek_change_notes(&group)
                .contains(&ChangeNote::ReinviteOwed),
        "a route that could not be read was taken for none: the Welcome was let go",
    );
    rename("welcome_routes_away", "welcome_routes");
    clock.set(2 * HOUR_MS);
    assert_eq!(changes.resume(&admin.circle).await.welcomes_sent, 1);
    assert!(welcomes(&outbox.handed())
        .iter()
        .all(
            |(event, relays)| recipient_of(event) == Some(invitee.pubkey_hex())
                && relays == &[INBOX]
        ));
}

/// A Welcome's record ends an hour before its gift wrap would fall below a
/// Haven invitee's inbox window (96 h; the wrap's `created_at` is backdated
/// up to two days), when that is sooner than a day from the hand-over: no
/// retry reaches a relay after the invitee could still see it (decision
/// 231).
#[tokio::test]
async fn a_welcome_is_not_sent_once_its_invitee_could_no_longer_see_it() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    outbox.withhold_welcome_to(&invitee.pubkey_hex());
    let clock = Clock::ahead_of_the_device(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    let (_, row) = the_row(&admin, &group).await;
    let built = admin
        .session()
        .welcome_created_at_for_test(&row.welcome_ids[0])
        .await
        .expect("the staged wrap's created_at");
    let lookback = u64::try_from(haven_core::relay::INBOX_RESUBSCRIBE_LOOKBACK_SECS).unwrap();
    let visible_until_ms = (built + lookback - 3_600) * 1_000;
    // Handed over two hours before that: a day from the hand-over would be
    // twenty-two hours too late.
    let handed_over_ms = visible_until_ms - 2 * HOUR_MS;
    let at = |instant_ms: u64| {
        clock.set(instant_ms - clock.now_ms() + clock.offset.load(Ordering::SeqCst));
    };
    at(handed_over_ms);
    transport.answer(ONE, [Answer::Accepted]);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        1,
        "premise: handed over and sent"
    );
    at(visible_until_ms - SECOND_MS);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(
        welcomes(&outbox.handed()).len(),
        1,
        "a Welcome owed was not sent before its invitee's window closed",
    );
    at(visible_until_ms);
    let _ = changes.resume(&admin.circle).await;
    at(visible_until_ms + HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome was sent after its invitee could no longer see it",
    );
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::WelcomeOwed],
        "the circle was not told the Welcome is still owed",
    );
}

/// A queued invite keeps its invitee's route for the advance that stages it;
/// one the next open retires stages no Welcome, and its route goes with it.
#[tokio::test]
async fn a_queued_invite_the_open_retires_takes_its_route_with_it() {
    let Gated { bob, group, .. } = a_circle_whose_changes_queue().await;
    let transport = ScriptedFanout::default();
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let (invitee, package) = an_invitee().await;
    let outcome = through(&transport, &outbox, &clock)
        .add_members(&bob.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(outcome.status, EvolutionStatus::Queued, "premise");
    assert_eq!(
        bob.session()
            .welcome_route_for_test(&group, &invitee.pubkey_hex()),
        Some(vec![INBOX.to_string()]),
        "a queued invite's route was not kept for the advance that stages it",
    );
    let bob = bob.reopen();
    assert!(
        bob.session()
            .welcome_route_for_test(&group, &invitee.pubkey_hex())
            .is_none(),
        "a retired invite's route was kept at rest",
    );
}

/// An invite that cannot be staged — the circle's earlier invite of the same
/// person is still awaiting its relays — puts back the route that earlier
/// invite kept, instead of taking it away: the earlier Welcome still goes.
#[tokio::test]
async fn an_invite_that_stages_nothing_leaves_an_earlier_invites_route_as_it_was() {
    const INBOX_TWO: &str = "wss://inbox-two.change-canary3d8f.example.com";

    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let first = changes
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(first.status, EvolutionStatus::Unresolved, "premise");
    let again = MemberKeyPackage {
        key_package_event: create_key_package_event(
            invitee.session(),
            &invitee.keys,
            &[INBOX_TWO.to_string()],
        )
        .await,
        inbox_relays: vec![INBOX_TWO.to_string()],
        nip65_relays: Vec::new(),
    };
    let second = changes.add_members(&admin.circle, &group, &[again]).await;
    assert!(
        second.as_ref().map_or(true, |outcome| outcome.status
            != EvolutionStatus::Unresolved
            && outcome.status != EvolutionStatus::Confirmed),
        "premise: the second invite stages nothing beside the first",
    );
    assert_eq!(
        admin
            .session()
            .welcome_route_for_test(&group, &invitee.pubkey_hex()),
        Some(vec![INBOX.to_string()]),
        "an invite that staged nothing took away the route an earlier invite still needs",
    );
}

// ── The resume ───────────────────────────────────────────────────────────────

/// A removal a kill left staged with no record is given one at the open, and
/// the session's first resume sends it: a relay that holds it, or takes it,
/// applies it, and the circle works again. With no relay answering it stays
/// staged — never undone — and its relays are asked again on their schedule.
#[tokio::test]
async fn a_kill_between_staging_a_removal_commit_and_its_fanout_put_leaves_the_group_recoverable() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    admin
        .session()
        .remove_members(&group, std::slice::from_ref(&removed))
        .await
        .expect("a removal is staged, and no record written");
    let admin = admin.reopen();
    assert!(
        staged_ref(&admin, &group).await.is_some() && !can_send(&admin, &group).await,
        "premise: the removal is staged, and the circle's sends wait",
    );
    let transport = answering(&[(ONE, &[Answer::Silent, Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let first = changes.resume(&admin.circle).await;
    assert!(!first.errored);
    assert_eq!(transport.calls().len(), 1, "the resume did not send it");
    assert!(staged_ref(&admin, &group).await.is_some());
    assert!(
        first.retry_after_ms.is_some(),
        "a commit still owed to a relay asked for no wake",
    );

    // Not due again yet: the relay is not called.
    clock.set(SECOND_MS);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(
        transport.calls().len(),
        0,
        "a resume called a relay that was not due",
    );

    clock.set(HOUR_MS);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(transport.calls().len(), 1);
    assert!(!roster(&admin, &group).await.contains(&removed));
    assert!(
        staged_ref(&admin, &group).await.is_none() && can_send(&admin, &group).await,
        "the circle does not work after the resume applied the repaired removal",
    );
}

/// A relay that keeps failing is called by resumes on its one schedule and
/// no more, however often the device resumes: here once a minute for three
/// hours, for a removal the relay never answers.
#[tokio::test]
async fn a_resume_every_minute_calls_a_failing_relay_on_its_schedule_and_no_more() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let outcome = changes
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("accepted");
    assert_eq!(outcome.status, EvolutionStatus::Unresolved);
    let mut calls: Vec<u64> = transport.calls().iter().map(|_| 0).collect();

    let mut at = 60 * SECOND_MS;
    while at < 3 * HOUR_MS {
        clock.set(at);
        let _ = changes.resume(&admin.circle).await;
        calls.extend(transport.calls().iter().map(|_| at));
        at += 60 * SECOND_MS;
    }
    assert_eq!(
        calls.iter().filter(|at| **at < HOUR_MS).count(),
        7,
        "calls to a silent relay in a change's first hour",
    );
    for hour in 1..3 {
        let in_hour = calls
            .iter()
            .filter(|at| **at >= hour * HOUR_MS && **at < (hour + 1) * HOUR_MS)
            .count();
        assert!(in_hour <= 1, "{in_hour} calls in hour {}", hour + 1);
    }
    assert!(outbox.handed().is_empty());
}

/// The resume built as the bridge's `*_driven` entries build it, over the
/// app's own transport and clock: it sends a commit left awaiting its relay
/// through Haven's publish pool — the frozen event, to the relay it was
/// frozen for — and applies it on that relay's acknowledgement. The relay is
/// in-process; the one real wait is its answer.
#[tokio::test]
async fn the_products_resume_sends_a_commit_left_awaiting_its_relay_and_applies_it() {
    let relay = ScriptedRelay::start();
    let fx = setup_circle(2, &[relay.url()]).await;
    let (admin, _others, group) = split(fx);
    let before = admin.session().epoch(&group).await.expect("epoch");
    // What a process killed before its first drive leaves behind.
    let staged = admin
        .circle
        .update_circle_relays_staging(
            &group,
            &[relay.url().to_string(), THREE.to_string()],
            Clock::ahead_of_the_device(0).now_ms(),
        )
        .await
        .expect("the change is staged");
    let id = staged.commit.expect("the change is recorded");
    let frozen = probe(&admin, &id).await.expect("the record exists");
    assert!(relay.published().is_empty(), "premise: nothing sent yet");

    let relays = RelayManager::new();
    let transport = relays.fanout_transport();
    let resumed = Publishing {
        fanout: &transport,
        publisher: &relays,
        clock: &WallClock,
        deadline_ms: Some(wake_deadline(&admin.circle, &WallClock, RESUME_BUDGET_MS)),
        mode: &DriveMode::Full,
    }
    .resume(&admin.circle)
    .await;

    assert!(!resumed.errored);
    assert_eq!(
        relay
            .published()
            .iter()
            .map(|event| event.id)
            .collect::<Vec<_>>(),
        [frozen.event_id],
        "the resume did not send the frozen commit to the relay it was frozen for",
    );
    assert_eq!(
        admin.session().epoch(&group).await.expect("epoch"),
        before + 1,
        "the commit its relay acknowledged was not applied",
    );
    assert_eq!(resumed.retry_after_ms, None);
}

/// From a day after it was staged, a commit a relay may hold asks for no
/// wake of its own: the same bytes sent on a timer from wherever the device
/// is would tell a relay that never answers where the device is, for as long
/// as it liked. It is still sent on the wakes the app has anyway, and still
/// no more than once an hour to a relay.
#[tokio::test]
async fn a_possibly_exposed_commit_asks_for_no_wake_of_its_own_after_its_first_day() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let outcome = changes
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("accepted");
    assert!(
        outcome.retry_after_ms.is_some(),
        "premise: in its first day it asks to be sent again",
    );
    transport.calls();

    clock.set(DAY_MS + HOUR_MS);
    let woken = changes.resume(&admin.circle).await;
    assert_eq!(
        transport.calls().len(),
        1,
        "a wake the app had did not send it"
    );
    assert_eq!(
        woken.retry_after_ms, None,
        "a commit a relay may hold asked for a wake of its own after its first day",
    );
    clock.set(DAY_MS + HOUR_MS + 60 * SECOND_MS);
    let _ = changes.resume(&admin.circle).await;
    assert_eq!(transport.calls().len(), 0, "sent twice inside an hour");
    clock.set(DAY_MS + 2 * HOUR_MS + SECOND_MS);
    let later = changes.resume(&admin.circle).await;
    assert_eq!(transport.calls().len(), 1);
    assert_eq!(later.retry_after_ms, None);
    assert!(staged_ref(&admin, &group).await.is_some(), "it was undone");
}

/// A record whose commit a relay may hold and the engine no longer stages
/// has no exit but the engine's own convergence pass, which the engine opens
/// only when something asks for the circle's deadline. The resume asks, and
/// serves it: the record is settled in that same resume and the circle takes
/// changes again.
#[tokio::test]
async fn a_resume_serves_the_deadline_of_a_circle_whose_record_the_engine_no_longer_holds() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("accepted");
    let (id, row) = the_row(&admin, &group).await;
    let pending = staged_ref(&admin, &group).await.expect("staged");
    let (db, key) = db_of(&admin);
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && commit_state(&admin, row.event_id).await == Some(MessageState::Sent),
        "premise: a relay may hold the commit and the engine no longer stages it",
    );
    transport.calls();

    clock.set(HOUR_MS);
    let resumed = changes.resume(&admin.circle).await;
    assert!(!resumed.errored);
    assert_ne!(
        commit_state(&admin, row.event_id).await,
        Some(MessageState::Sent),
        "the resume did not have the engine dispose of a commit it no longer stages",
    );
    assert_ne!(
        probe(&admin, &id).await.map(|row| row.mls),
        Some(FanoutMls::Pending),
        "the record was left pending behind a commit the engine had disposed of",
    );
    assert_eq!(
        transport.calls().len(),
        0,
        "nothing is sent under such a record"
    );
    // The engine gave a commit a relay had been sent a final state without
    // applying it: the rest of the circle may have. That is said.
    assert_eq!(
        admin.session().take_change_notes(&group),
        [ChangeNote::MayBeOutOfStep],
        "a commit a relay may hold was set aside for good and its circle was not told",
    );
    admin
        .session()
        .remove_members(&group, &[others[0].pubkey_hex()])
        .await
        .expect("the circle takes a change again");
}

/// A drive that ends on an error is said, in a line that names nothing, and
/// reported — and is never read as a failed change: the commit is neither
/// undone nor lost, and the next resume applies it.
#[tokio::test]
async fn a_resume_that_ends_on_an_error_says_so_and_undoes_nothing() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    admin.session().fail_next_confirms_for_test(&[false]);
    let mut outcome = None;
    let lines = capture_haven_log(Box::pin(async {
        outcome = Some(
            changes
                .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
                .await,
        );
    }))
    .await;
    let outcome = outcome
        .expect("ran")
        .unwrap_or_else(|_| panic!("a change whose confirm failed was reported as an error"));
    assert_eq!(
        outcome.status,
        EvolutionStatus::Unresolved,
        "a change whose confirm returned an error was reported as failed or as applied",
    );
    let (_, row) = the_row(&admin, &group).await;
    assert_no_needles(
        std::slice::from_ref(line_saying(&lines, "a drive ended on an error")),
        &[
            &hex::encode(group.as_slice()),
            &row.event_id.to_hex(),
            &removed,
            CANARY,
        ],
    );
    assert_eq!(row.statuses, [FanoutTargetStatus::Accepted]);
    assert!(staged_ref(&admin, &group).await.is_some());

    let resumed = changes.resume(&admin.circle).await;
    assert!(!resumed.errored);
    assert!(!roster(&admin, &group).await.contains(&removed));
    assert_eq!(transport.calls().len(), 1, "a relay was written to again");
}

/// A change staged with too little of the wake left to see a row through is
/// left awaiting relays — staged and recorded — and not begun.
#[tokio::test]
async fn a_change_staged_at_the_end_of_a_wake_is_left_awaiting_and_not_begun() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: &clock,
        deadline_ms: Some(clock.now_ms() + SECOND_MS),
        mode: &DriveMode::Full,
    };
    let outcome = changes
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("accepted");
    assert_eq!(outcome.status, EvolutionStatus::Unresolved);
    assert_eq!(
        transport.calls().len(),
        0,
        "a row was begun past the wake's end"
    );
    let (_, row) = the_row(&admin, &group).await;
    assert_eq!(row.statuses, [FanoutTargetStatus::NotAttempted]);
}

/// A removal killed inside the engine's staging call — after the commit was
/// attached to the group and before its own row was stored — leaves a
/// staged commit no relay was sent, with nothing in the store that names it:
/// no row for the open's repair to find, and nothing the engine restores a
/// pending state from. The engine leaves a member-removing staged commit in
/// place at its open (`cgka-engine/src/engine.rs` 1961-1975).
///
/// What that circle does, on the real engine: it shares as before — the
/// removal simply did not happen — and the next change asked of it is
/// refused ONCE, the engine clearing the leftover on that failed attempt's
/// way out (`cgka-engine/src/pending_commit_guard.rs`); the same change asked
/// again is staged, sent and applied. Nothing of Haven's takes part in that,
/// and nothing of Haven's is needed for it.
#[tokio::test]
async fn a_removal_killed_before_its_commit_was_stored_is_cleared_by_the_next_change_asked() {
    use cgka_traits::storage::{GroupStorage, MessageStorage};

    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    // The circle's record as it stood before the staging call.
    let mut record = None;
    let admin = with_closed_store(admin, |store| {
        record = Some(store.get_group(&group).expect("the circle's record"));
    });
    let record = record.expect("read");
    let staged = admin
        .session()
        .remove_members(&group, std::slice::from_ref(&removed))
        .await
        .expect("the removal is staged");
    let commit = staged
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::GroupEvolution { msg, .. } => Some(msg.id.clone()),
            _ => None,
        })
        .expect("its commit");
    // Killed before the commit's row and the record's new roster were
    // written: both are taken back, and the staged commit stays attached.
    let admin = with_closed_store(admin, |store| {
        store.put_group(&record).expect("the record is put back");
        store
            .delete_message(&commit)
            .expect("the commit's row is taken out");
    });

    // The circle shares as before, with everybody it had.
    assert!(staged_ref(&admin, &group).await.is_none() && rows_of(&admin, &group).await.is_empty());
    assert_eq!(roster(&admin, &group).await.len(), 3);
    let fix = seal(&admin, &group)
        .await
        .expect("a circle left in this state still shares");
    for peer in &others {
        assert_eq!(
            peer.circle
                .ingest_for_test(&fix)
                .await
                .expect("a peer ingests it")
                .len(),
            1,
            "a member of the circle could not read what was shared",
        );
    }

    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    assert!(
        changes
            .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
            .await
            .is_err(),
        "the first change after the kill was not refused: the engine now clears the leftover \
         commit by itself — say so in T-KILL-WINDOW",
    );
    assert!(transport.calls().is_empty() && rows_of(&admin, &group).await.is_empty());

    let again = changes
        .remove_members(&admin.circle, &group, std::slice::from_ref(&removed))
        .await
        .expect("the same change asked again is accepted");
    assert_eq!(again.status, EvolutionStatus::Confirmed);
    assert!(!roster(&admin, &group).await.contains(&removed));
    assert!(staged_ref(&admin, &group).await.is_none() && can_send(&admin, &group).await);
}

// ── A departure left half-made by a kill ─────────────────────────────────────

/// A circle of three in which the last member has left and the first's
/// process died INSIDE the engine's staging of the eviction: after `OpenMLS`
/// stored the leaver's proposal and the commit, before the commit's own row
/// and the circle's new record were written. Both are taken back in the
/// closed store; what `OpenMLS` stored stays.
struct HalfMadeDeparture {
    admin: CircleMember,
    stayer: CircleMember,
    leaver: CircleMember,
    group: GroupId,
    /// The leaver's proposal: what any other member needs to commit it.
    leave: nostr::Event,
}

async fn a_departure_left_half_made_by_a_kill() -> HalfMadeDeparture {
    a_departure_left_half_made_by_a_kill_on(&[ONE]).await
}

/// As [`a_departure_left_half_made_by_a_kill`], in a circle on `relays`.
async fn a_departure_left_half_made_by_a_kill_on(relays: &[&str]) -> HalfMadeDeparture {
    use cgka_traits::storage::{GroupStorage, MessageStorage};
    use haven_core::nostr::mls::types::EpochId;

    let fx = setup_circle(3, relays).await;
    let (admin, mut others, group) = split(fx);
    let leaver = others.remove(1);
    let stayer = others.remove(0);
    let left = leaver
        .session()
        .leave_group(&group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let leave = SessionManager::proposal_events(&left.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    admin
        .session()
        .process_event(&leave)
        .await
        .expect("the leave is ingested");
    // The store as it stood before the staging call.
    let mut before = None;
    let admin = with_closed_store(admin, |store| {
        let record = store.get_group(&group).expect("the circle's record");
        let rows: Vec<MessageId> = store
            .list_messages(&group, EpochId(0))
            .expect("the circle's rows")
            .into_iter()
            .map(|row| row.id)
            .collect();
        before = Some((record, rows));
    });
    let (record, rows) = before.expect("read");
    for _ in 0..8 {
        if staged_ref(&admin, &group).await.is_some() {
            break;
        }
        if let Some(wait) = admin.session().receive_retick_after(&group).await {
            tokio::time::sleep(wait).await;
        }
        let _ = admin.session().stage_unrecorded_for_test(&group).await;
    }
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "premise: the eviction is staged",
    );
    let admin = with_closed_store(admin, |store| {
        store.put_group(&record).expect("the record is put back");
        for row in store.list_messages(&group, EpochId(0)).expect("rows") {
            if !rows.contains(&row.id) {
                store.delete_message(&row.id).expect("the row is taken out");
            }
        }
    });
    HalfMadeDeparture {
        admin,
        stayer,
        leaver,
        group,
        leave,
    }
}

/// `member` commits the departure `leave` announces — the engine's own
/// eviction, applied as on a relay's acknowledgement — and hands back the
/// commit for the others.
async fn evicts(member: &CircleMember, group: &GroupId, leave: &nostr::Event) -> nostr::Event {
    member
        .session()
        .process_event(leave)
        .await
        .expect("the leave is ingested");
    for _ in 0..8 {
        if let Some(wait) = member.session().receive_retick_after(group).await {
            tokio::time::sleep(wait).await;
        }
        let effects = member
            .session()
            .stage_unrecorded_for_test(group)
            .await
            .expect("advance");
        let staged = effects.publish.iter().find_map(|work| match work {
            PublishWork::AutoPublish { msg, pending } => Some((msg.clone(), *pending)),
            _ => None,
        });
        if let Some((msg, pending)) = staged {
            member
                .circle
                .session()
                .confirm_published(pending)
                .await
                .expect("the eviction is applied");
            return SessionManager::transport_message_to_event(&msg).expect("the commit");
        }
    }
    panic!("the eviction was never staged");
}

/// An eviction killed inside its own staging leaves a circle that reads
/// healthy and cannot share: stable, nothing staged, no record, the member
/// who left still listed — and every location refused, because `OpenMLS` will
/// not seal while the leaver's proposal sits in its store. The engine never
/// stages the eviction again, here or after a restart, and nothing it stores
/// names the state. What Haven can do is say so, typed, at the foreground's
/// send that fails (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW).
///
/// It ends when a commit for the departure is applied on this device: the
/// other remaining member's eviction, here.
#[tokio::test]
async fn an_eviction_killed_inside_its_staging_leaves_a_circle_that_cannot_share_and_says_why() {
    let HalfMadeDeparture {
        admin,
        stayer,
        leaver,
        group,
        leave,
    } = a_departure_left_half_made_by_a_kill().await;
    let clock = Clock::at(0);

    assert!(
        matches!(
            admin.session().epoch_state(&group).await,
            Some(EpochState::Stable { .. })
        ) && rows_of(&admin, &group).await.is_empty(),
        "the engine now restores or announces a commit killed inside its staging: \
         say so in T-KILL-WINDOW",
    );
    assert!(roster(&admin, &group).await.contains(&leaver.pubkey_hex()));
    // The foreground's send: one that makes no commit is held while the
    // eviction is due, before the engine is asked to seal.
    let refused =
        haven_core::relay::fanout::Publishing::<'_, haven_core::relay::fanout::scripted::Inert> {
            fanout: &haven_core::relay::fanout::scripted::Inert,
            publisher: &haven_core::relay::fanout::scripted::Inert,
            clock: &haven_core::relay::fanout::WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .seal_location(
            &admin.circle,
            &group,
            &haven_core::location::LocationMessage::new(51.5, -0.12),
        )
        .await;
    assert!(
        matches!(
            refused,
            Err(haven_core::circle::CircleError::SendBlockedByDeparture)
        ),
        "a circle that cannot share behind a half-made departure did not say so",
    );
    // The engine goes on announcing the eviction's deadline, and stages
    // nothing when it is served.
    for _ in 0..3 {
        if let Some(wait) = admin.session().eviction_due_after_for_test(&group).await {
            tokio::time::sleep(wait + std::time::Duration::from_millis(5)).await;
        }
        let advanced = admin
            .session()
            .advance_for_drive(&group, clock.now_ms())
            .await
            .expect("the advance runs");
        assert!(
            advanced.fanouts.is_empty() && staged_ref(&admin, &group).await.is_none(),
            "the engine staged the eviction again: T-KILL-WINDOW's eviction half is closed",
        );
    }
    // The next process finds the same.
    let admin = admin.reopen();
    assert!(!can_send(&admin, &group).await && staged_ref(&admin, &group).await.is_none());

    // The other remaining member commits the departure; its commit heals
    // this device.
    let theirs = evicts(&stayer, &group, &leave).await;
    admin
        .session()
        .process_event_settled_for_test(&theirs)
        .await
        .expect("the peer's eviction is ingested");
    assert!(!roster(&admin, &group).await.contains(&leaver.pubkey_hex()));
    let fix = seal(&admin, &group)
        .await
        .expect("the circle shares again once the departure is committed");
    assert_eq!(
        stayer
            .circle
            .ingest_for_test(&fix)
            .await
            .expect("the peer ingests it")
            .len(),
        1,
    );
    assert!(
        leaver
            .circle
            .ingest_for_test(&fix)
            .await
            .map_or(true, |read| read.is_empty()),
        "the member who left reads what the circle seals after the eviction",
    );
}

/// A change made over a half-made departure commits the departure with it:
/// the engine's builder takes in the leaver's stored proposal by reference,
/// while the roster it projects is the one the change asked for. Such a
/// commit removes a member whatever it was meant to do, so it is never marked
/// as removing nobody, and a day without a reachable relay does not undo it:
/// undone, the circle's waiting locations would go to the member who left.
#[tokio::test]
async fn a_change_made_over_a_half_made_departure_is_never_undone_for_want_of_a_relay() {
    let HalfMadeDeparture {
        admin,
        leaver,
        group,
        ..
    } = a_departure_left_half_made_by_a_kill().await;
    let transport = answering(&[(ONE, &[Answer::Unreachable])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);

    let outcome = changes
        .update_relays(&admin.circle, &group, &[ONE.to_string(), TWO.to_string()])
        .await
        .expect("a relay change is accepted over the leftover");
    assert_eq!(outcome.status, EvolutionStatus::Unresolved);
    let (id, _) = the_row(&admin, &group).await;
    for at in [DAY_MS, 2 * DAY_MS, 30 * DAY_MS] {
        clock.set(at);
        let driven = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
            .await
            .unwrap_or_else(|_| panic!("the drive runs"));
        assert_eq!(
            driven.status,
            FanoutStatus::Unresolved,
            "a commit that evicts a member by reference was undone at the bound ({at} ms)",
        );
    }
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && admin.session().peek_change_notes(&group).is_empty(),
    );

    // The first relay to answer applies it: the relay change, and the
    // departure with it.
    transport.answer(ONE, [Answer::Accepted]);
    clock.set(31 * DAY_MS);
    let applied = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the drive runs"));
    assert_eq!(applied.status, FanoutStatus::Confirmed);
    assert!(
        !roster(&admin, &group).await.contains(&leaver.pubkey_hex()),
        "premise: the change committed the departure by reference",
    );
    assert!(can_send(&admin, &group).await);
}

/// A sweep whose convergence drain runs out of the deadlines it may wait out,
/// with the engine still owing one, hands the circle's advance to the next
/// sweep — as a sweep its deadline cut does — so it is not left until the
/// circle's next send, ingest or open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_sweep_out_of_deadlines_hands_its_advance_to_the_next_sweep() {
    let relay = ScriptedRelay::start();
    let HalfMadeDeparture { admin, group, .. } =
        a_departure_left_half_made_by_a_kill_on(&[relay.url()]).await;
    assert!(
        admin
            .session()
            .eviction_due_after_for_test(&group)
            .await
            .is_some(),
        "premise: the engine announces the eviction's deadline",
    );
    let swept = haven_core::relay::catchup::run_catchup_all_circles(
        &admin.circle,
        &RelayManager::new(),
        60,
    )
    .await;
    assert!(
        !swept.deadline_hit && admin.session().take_owed_advance().contains(&group),
        "a sweep whose drain ran out of deadlines left the circle's advance to nobody",
    );
}

/// The live plane's drain out of deadlines is come back for after the next
/// open — a burst — on the worker, behind the relay's end of stored events:
/// the engine's deadlines are served again, and the worker is done with it
/// before a pause.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_drain_out_of_deadlines_is_come_back_for_after_the_next_open() {
    let relay = ScriptedRelay::start();
    let HalfMadeDeparture { admin, group, .. } =
        a_departure_left_half_made_by_a_kill_on(&[relay.url()]).await;
    let routed = admin
        .circle
        .get_circle(&group)
        .await
        .expect("the circle store is read")
        .expect("the circle exists")
        .circle
        .nostr_group_id;
    let spec = haven_core::relay::live_sync::CircleSpec {
        group_id_hex: hex::encode(routed),
        relays: vec![relay.url().to_owned()],
    };
    let core = haven_core::relay::live_sync::LiveSyncCore::new_local(
        Arc::clone(&admin.circle),
        admin.keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(std::slice::from_ref(&spec), &[])
        .await
        .expect("the session starts");
    admin.session().until_caught_up_for_test(&group).await;
    core.pause_subscriptions().await.expect("the plane pauses");
    let before = core.processor().convergence_reticks();
    core.open_background_burst().await.expect("a burst opens");
    assert!(
        matches!(
            core.wait_backlog_settled().await,
            haven_core::relay::live_sync::BacklogOutcome::Settled
        ),
        "premise: the burst's relay answered with its end of stored events",
    );
    // Queued behind whatever the worker is doing.
    core.pause_subscriptions().await.expect("the plane pauses");
    assert!(
        core.processor().convergence_reticks() > before,
        "a drain that ran out of deadlines was not come back for after the next open",
    );
    let _ = core.stop().await;
}

/// The come-back after an open runs inputs only, whatever the lifecycle: a
/// due eviction is left for the drive, which stages one only once its circle
/// is caught up — never by a come-back, even in the foreground.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_come_back_after_an_open_stages_no_eviction_even_in_the_foreground() {
    use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveDriver};

    let fx = setup_circle(3, &[ONE]).await;
    let leave = helpers::drive::leave_of(&fx, 2).await;
    let (admin, others, group) = split(fx);
    helpers::drive::make_a_departure_due(&admin, &others[0], &group, &leave).await;
    let transport = Arc::new(ScriptedFanout::default());
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn haven_core::relay::fanout::FanoutSend>,
            publisher: Arc::new(Outbox::default()),
            clock: Arc::new(Clock::at(0)),
        },
    );
    processor.for_test().note_launched();
    assert!(
        processor.for_test().prove_foreground(),
        "premise: the foreground"
    );
    admin.session().owe_advance(std::slice::from_ref(&group));
    processor.for_test().owe_come_back();
    processor.for_test().come_back_if_owed().await;
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && rows_of(&admin, &group).await.is_empty()
            && transport.call_count() == 0
            && admin
                .session()
                .eviction_due_after_for_test(&group)
                .await
                .is_some(),
        "a come-back in the foreground staged an eviction left due",
    );
}

/// A circle whose eviction was killed inside its staging announces that
/// eviction's deadline — ten to fifty milliseconds out — for good, and stages
/// nothing when it is served. The live plane arms no timer on it: one event,
/// and one drive, wait out at most the bounded number of deadlines a
/// convergence drain allows, and a drive asks to be run again for nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deadline_announced_for_good_costs_the_live_plane_a_bounded_wait_per_event_and_no_timer()
{
    use haven_core::relay::live_sync::{EngineProcessor, EventBus, LiveDriver};
    use haven_core::relay::retick::MAX_CONVERGENCE_RETICKS;

    let HalfMadeDeparture {
        admin,
        stayer,
        group,
        ..
    } = a_departure_left_half_made_by_a_kill().await;
    let transport = Arc::new(ScriptedFanout::default());
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn haven_core::relay::fanout::FanoutSend>,
            publisher: Arc::new(Outbox::default()),
            clock: Arc::new(Clock::at(0)),
        },
    );
    processor.for_test().set_background_burst(false);
    let routed = admin
        .circle
        .get_circle(&group)
        .await
        .expect("the circle store is read")
        .expect("the circle exists")
        .circle
        .nostr_group_id;
    assert!(
        admin
            .session()
            .eviction_due_after_for_test(&group)
            .await
            .is_some(),
        "premise: the engine announces the eviction's deadline",
    );

    let mut waited = Vec::new();
    for _ in 0..3 {
        let before = processor.convergence_reticks();
        let inbound = seal(&stayer, &group).await.expect("a peer shares");
        processor.process_group_event(&inbound, &routed).await;
        processor.for_test().drive_due().await;
        waited.push(processor.convergence_reticks() - before);
        assert!(
            staged_ref(&admin, &group).await.is_none() && rows_of(&admin, &group).await.is_empty(),
            "premise: nothing is ever staged in this state",
        );
    }
    assert!(
        waited
            .iter()
            .all(|reticks| *reticks <= MAX_CONVERGENCE_RETICKS),
        "one event made the live plane wait out more deadlines than a drain allows",
    );
    assert!(
        waited.iter().any(|reticks| *reticks > 0),
        "premise: the deadline is served at all, or this bounds nothing",
    );
    assert_eq!(
        (processor.drive_retry_after_ms(), transport.call_count()),
        (None, 0),
        "a drive asked to be woken, or called a relay, for a deadline nothing comes of",
    );
}

/// A removal the engine staged for a member who left is NOT given a record
/// by the next open when the process died before any obligation for it was
/// written. With none the circle reads stable, and the eviction the other
/// remaining member commits for the same departure is applied here and the
/// circle sends and reads again. Under a record nothing drives, that commit
/// would be held unread behind it for good.
#[tokio::test]
async fn an_eviction_a_kill_left_with_no_record_is_healed_by_another_members_commit() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, mut others, group) = split(fx);
    let leaver = others.remove(1);
    let stayer = others.remove(0);
    let left = leaver
        .session()
        .leave_group(&group)
        .await
        .expect("the leave is proposed")
        .expect("a fresh leave");
    let leave = SessionManager::proposal_events(&left.publish)
        .into_iter()
        .next()
        .expect("the leave proposal");
    admin
        .session()
        .process_event(&leave)
        .await
        .expect("the leave is ingested");
    for _ in 0..8 {
        if staged_ref(&admin, &group).await.is_some() {
            break;
        }
        if let Some(wait) = admin.session().receive_retick_after(&group).await {
            tokio::time::sleep(wait).await;
        }
        // The legacy plane's advance: the commit is handed back, and the
        // process dies before its obligation is written.
        let _ = admin.session().stage_unrecorded_for_test(&group).await;
    }
    assert!(
        staged_ref(&admin, &group).await.is_some(),
        "premise: staged"
    );

    let admin = admin.reopen();
    assert!(
        rows_of(&admin, &group).await.is_empty(),
        "an eviction found staged with no record was given one that nothing drives",
    );
    assert!(
        !matches!(
            admin.session().epoch_state(&group).await,
            Some(EpochState::PendingPublish(_))
        ),
        "the circle's traffic is held behind an eviction nothing can send",
    );

    let theirs = evicts(&stayer, &group, &leave).await;
    admin
        .session()
        .process_event_settled_for_test(&theirs)
        .await
        .expect("the peer's eviction is ingested, not held");
    assert!(!roster(&admin, &group).await.contains(&leaver.pubkey_hex()));
    let fix = seal(&admin, &group)
        .await
        .expect("the circle sends again after the peer's commit");
    assert_eq!(
        stayer
            .circle
            .ingest_for_test(&fix)
            .await
            .expect("the peer ingests it")
            .len(),
        1,
    );
    let theirs = seal(&stayer, &group).await.expect("the peer shares");
    assert_eq!(
        admin
            .circle
            .ingest_for_test(&theirs)
            .await
            .expect("this device reads again")
            .len(),
        1,
    );
}

// ── A wake's budget bounds the whole call ────────────────────────────────────

/// A Welcome's send takes as long as its publisher's own ladder. A wake with
/// room for the invite's commit and none for that does not begin it: the
/// Welcome stays in its record and the engine's outstanding one, and the next
/// drive sends it.
#[tokio::test]
async fn a_welcome_the_wake_has_no_room_for_stays_in_its_record_and_goes_with_the_next_drive() {
    let fx = setup_circle(2, &[ONE]).await;
    let (admin, _others, group) = split(fx);
    let (_invitee, package) = an_invitee().await;
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let short = Publishing {
        fanout: &transport,
        publisher: &outbox,
        clock: &clock,
        deadline_ms: Some(clock.now_ms() + ROW_BUDGET_MS + SECOND_MS),
        mode: &DriveMode::Full,
    };

    let outcome = short
        .add_members(&admin.circle, &group, &[package])
        .await
        .expect("the invite is accepted");
    assert_eq!(outcome.status, EvolutionStatus::Confirmed);
    assert_eq!((outcome.welcomes_sent, outcome.welcomes_total), (0, 1));
    assert!(
        welcomes(&outbox.handed()).is_empty(),
        "a Welcome was begun in a wake that could not have waited it out",
    );

    let resumed = through(&transport, &outbox, &clock)
        .resume(&admin.circle)
        .await;
    assert_eq!(
        resumed.welcomes_sent, 1,
        "a Welcome a short wake left was not sent by the next drive",
    );
    let handed = outbox.handed();
    assert_eq!(welcomes(&handed).len(), 1);
    assert_eq!(welcomes(&handed)[0].1, [INBOX.to_string()]);
}

/// A record the engine no longer holds staged can only be settled by the
/// engine's own pass. A resume that could not make that happen says when the
/// engine's deadline for the circle is due, instead of nothing: never sooner
/// than a busy relay is asked again, so nothing spins on it.
#[tokio::test]
async fn a_record_still_unheld_after_a_resume_says_when_the_engine_is_due() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let transport = answering(&[(ONE, &[Answer::Silent])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let changes = through(&transport, &outbox, &clock);
    let _ = changes
        .remove_members(&admin.circle, &group, &[others[1].pubkey_hex()])
        .await
        .expect("accepted");
    let (id, row) = the_row(&admin, &group).await;
    let pending = staged_ref(&admin, &group).await.expect("staged");
    let (db, key) = db_of(&admin);
    set_stored_message_write_fault_for_test(&db, &key, true).expect("arm");
    let _ = admin
        .session()
        .publish_failed_past_its_fanout_for_test(pending)
        .await;
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && commit_state(&admin, row.event_id).await == Some(MessageState::Sent),
        "premise: a relay may hold the commit and the engine no longer stages it",
    );
    transport.calls();

    // The engine's pass cannot restate the commit while the store refuses
    // it: the record is still unheld when the resume returns.
    clock.set(HOUR_MS);
    let resumed = changes.resume(&admin.circle).await;
    set_stored_message_write_fault_for_test(&db, &key, false).expect("disarm");
    assert_eq!(
        probe(&admin, &id).await.map(|row| row.mls),
        Some(FanoutMls::Pending),
        "premise: still unheld",
    );
    assert!(
        resumed
            .retry_after_ms
            .is_some_and(|wait| wait >= BUSY_RETRY_MS),
        "a record only the engine's next pass can settle asked for no wake, or for one at once",
    );
    assert_eq!(transport.calls().len(), 0);
}

// ── A commit that could be neither recorded nor undone ───────────────────────

/// Stages `removed`'s removal with the record's write and the rollback both
/// failing, and returns what the caller was told.
async fn remove_with_neither_a_record_nor_a_rollback(
    admin: &CircleMember,
    group: &GroupId,
    removed: &str,
    transport: &ScriptedFanout,
    outbox: &Outbox,
    clock: &Clock,
) -> EvolutionStatus {
    let (db, key) = db_of(admin);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::OwnCommitIntentDelete, true)
        .expect("arm");
    let outcome = through(transport, outbox, clock)
        .remove_members(&admin.circle, group, &[removed.to_owned()])
        .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    set_engine_write_fault_for_test(&db, &key, EngineWrite::OwnCommitIntentDelete, false)
        .expect("disarm");
    outcome
        .unwrap_or_else(|_| {
            panic!("a change left staged was reported as an error, which says nothing was staged")
        })
        .status
}

/// A commit whose record cannot be written and whose rollback fails too is
/// staged with nothing to send it. Its author is told exactly that — not
/// "failed", which would say nothing was staged — the circle keeps a note,
/// nothing is sent, and the next staging hold tries the rollback again:
/// nothing ever left the device, so undoing it then is as safe as undoing it
/// at once.
#[tokio::test]
async fn a_commit_neither_recorded_nor_undone_is_said_and_undone_at_the_next_hold() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);

    let told = remove_with_neither_a_record_nor_a_rollback(
        &admin, &group, &removed, &transport, &outbox, &clock,
    )
    .await;
    assert_eq!(told, EvolutionStatus::Unrecorded);
    assert!(
        transport.calls().is_empty() && outbox.handed().is_empty(),
        "a commit with no record was sent",
    );
    assert!(staged_ref(&admin, &group).await.is_some() && rows_of(&admin, &group).await.is_empty());
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUnrecorded]
    );

    // The next staging hold undoes it: a send's, which is deferred while it
    // runs, or the advance's after it.
    let mut advanced = None;
    let mut sent = None;
    let lines = Box::pin(capture_haven_log(async {
        sent = Some(can_send(&admin, &group).await);
        advanced = Some(
            admin
                .session()
                .advance_for_drive(&group, clock.now_ms())
                .await,
        );
    }))
    .await;
    assert_eq!(sent, Some(false), "a send was sealed past a staged commit");
    let advanced = advanced
        .expect("ran")
        .unwrap_or_else(|_| panic!("the advance runs"));
    assert!(advanced.fanouts.is_empty());
    assert_no_needles(
        std::slice::from_ref(line_saying(
            &lines,
            "a commit left staged with no record was rolled back unsent",
        )),
        &[
            &hex::encode(group.as_slice()),
            &admin.pubkey_hex(),
            &removed,
            CANARY,
        ],
    );
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && roster(&admin, &group).await.contains(&removed)
            && can_send(&admin, &group).await,
        "a commit nothing could send was left holding its circle past the next hold",
    );
    assert!(transport.calls().is_empty());
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUnrecorded],
        "the circle is no longer told a change of its could not be recorded",
    );
}

/// The same commit when the process dies before any later hold: the next
/// open finds a removal staged with no record and gives it one, and the
/// first relay to answer applies it. The user was told it could not be
/// recorded, and the note saying so is still there — a change must not take
/// effect after its author was told otherwise with nothing to say why.
#[tokio::test]
async fn a_commit_neither_recorded_nor_undone_is_still_noted_when_the_next_open_sends_it() {
    let fx = setup_circle(3, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let removed = others[1].pubkey_hex();
    let transport = answering(&[(ONE, &[Answer::Accepted])]);
    let outbox = Outbox::default();
    let clock = Clock::at(0);
    let told = remove_with_neither_a_record_nor_a_rollback(
        &admin, &group, &removed, &transport, &outbox, &clock,
    )
    .await;
    assert_eq!(told, EvolutionStatus::Unrecorded);

    let admin = admin.reopen();
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUnrecorded],
        "the note did not survive the process",
    );
    let (id, row) = the_row(&admin, &group).await;
    assert_eq!(row.mls, FanoutMls::Pending);
    clock.set(SECOND_MS);
    let driven = drive_one(&admin.circle, &transport, &clock, &id, &DriveMode::Full)
        .await
        .unwrap_or_else(|_| panic!("the repaired removal is driven"));
    assert_eq!(driven.status, FanoutStatus::Confirmed);
    assert!(!roster(&admin, &group).await.contains(&removed));
    assert_eq!(
        admin.session().peek_change_notes(&group),
        [ChangeNote::ChangeUnrecorded]
    );
}
