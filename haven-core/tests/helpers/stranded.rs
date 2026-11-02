//! Fixtures for the tests of what the engine parks behind a pending commit
//! and leaves there (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY).
//!
//! Real MDK engines over `SQLCipher` stores, no relay. "The process ends" is
//! a member's stores closed and opened again: with its circle store
//! ([`CircleMember::reopen`]), which is the device as Haven runs it, or as the
//! engine alone ([`bare`]), which is MDK with none of what Haven does for a
//! circle that has a store.

use base64::Engine as _;
use cgka_engine::message_processor::MAX_PEEL_DEFERRED_ROWS_PER_GROUP;
use haven_core::nostr::mls::storage::{
    set_epoch_anchor_write_fault_for_test, set_stored_message_write_fault_naming_for_test,
};
use haven_core::nostr::mls::types::{
    GroupId, HeldRowKind, HeldRowProbe, IngestOutcome, LocationMessageResult, MessageState,
    PendingStateRef, PublishWork, ScreenedIngest, SessionEffects,
};
use haven_core::nostr::mls::{SessionManager, StorageConfig};
use nostr::{Event, EventBuilder, Keys, Timestamp};

use super::drive::{epoch, leave_of, sealed_by, wait_out_the_engine};
use super::{CircleFixture, CircleMember};

pub const ONE: &str = "wss://one.stranded-canary7d2a.example.com";
pub const TWO: &str = "wss://two.stranded-canary7d2a.example.com";
pub const THREE: &str = "wss://three.stranded-canary7d2a.example.com";
pub const CANARY: &str = "stranded-canary7d2a";

pub fn split(fx: CircleFixture) -> (CircleMember, Vec<CircleMember>, GroupId) {
    let mut members = fx.members;
    let admin = members.remove(0);
    (admin, members, fx.group)
}

pub fn mls_db(dir: &std::path::Path) -> (std::path::PathBuf, storage_sqlite::SqlCipherKey) {
    (
        StorageConfig::new(dir).database_path(),
        StorageConfig::test_sqlcipher_key().expect("test key"),
    )
}

/// A member's engine with no circle store behind it.
pub struct Bare {
    pub session: SessionManager,
    pub keys: Keys,
    pub dir: tempfile::TempDir,
}

impl Bare {
    /// Ends this process and opens the member again WITH its circle store.
    pub fn with_its_circle_store(self) -> CircleMember {
        let Self { session, keys, dir } = self;
        drop(session);
        let circle = std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys)
                .expect("the stores reopen"),
        );
        CircleMember { circle, keys, dir }
    }
}

/// Ends `member`'s process and opens its engine alone over the same store.
pub fn bare(member: CircleMember) -> Bare {
    let CircleMember { circle, keys, dir } = member;
    drop(
        std::sync::Arc::try_unwrap(circle)
            .unwrap_or_else(|_| panic!("the member's manager is still shared")),
    );
    let session = SessionManager::new_unencrypted(dir.path(), &keys).expect("the engine reopens");
    Bare { session, keys, dir }
}

/// The commit `effects` staged, as the event a relay would carry, and its
/// ref, when it staged one.
pub fn try_staged(effects: &SessionEffects) -> Option<(Event, PendingStateRef)> {
    effects.publish.iter().find_map(|work| match work {
        PublishWork::GroupEvolution { msg, pending, .. }
        | PublishWork::AutoPublish { msg, pending } => Some((
            SessionManager::transport_message_to_event(msg).ok()?,
            *pending,
        )),
        _ => None,
    })
}

pub fn staged(effects: &SessionEffects) -> (Event, PendingStateRef) {
    try_staged(effects).expect("the call staged a commit")
}

/// Stages a relay change the legacy way: pending, with no record.
pub async fn stage_relays(
    session: &SessionManager,
    group: &GroupId,
    relays: &[&str],
) -> (Event, PendingStateRef) {
    let effects = session
        .update_relays(group, relays.iter().map(ToString::to_string).collect())
        .await
        .expect("a relay change is staged");
    staged(&effects)
}

pub async fn answer(session: &SessionManager, event: &Event) -> IngestOutcome {
    match session.process_event(event).await.expect("the ingest runs") {
        ScreenedIngest::Ingested(ingest) => ingest.outcome,
        ScreenedIngest::RejectedBeforeAuth(_) => panic!("a genuine envelope passes the screen"),
    }
}

pub async fn parks(session: &SessionManager, event: &Event) -> bool {
    matches!(answer(session, event).await, IngestOutcome::Buffered { .. })
}

pub async fn held(session: &SessionManager, group: &GroupId) -> Vec<HeldRowProbe> {
    session
        .held_rows_for_test(group)
        .await
        .expect("the store is read")
}

/// How many of `rows` are an event nobody opened, stored `Retryable`: the
/// shape of what is parked behind a pending commit, and of what is stranded.
pub fn unopened_retryable(rows: &[HeldRowProbe]) -> usize {
    rows.iter()
        .filter(|row| row.keeps == HeldRowKind::Unopened && row.state == MessageState::Retryable)
        .count()
}

/// Whether `rows` are exactly `count` events nobody opened, each stored
/// `Retryable` under `epoch`.
pub fn all_parked_at(rows: &[HeldRowProbe], count: usize, epoch: u64) -> bool {
    rows.len() == count
        && unopened_retryable(rows) == count
        && rows.iter().all(|row| row.epoch.0 == epoch)
}

/// The locations `effects` deliver, in order.
pub fn fixes(effects: &SessionEffects) -> Vec<LocationMessageResult> {
    effects
        .events
        .iter()
        .filter_map(SessionManager::location_result_from_event)
        .filter(|result| matches!(result, LocationMessageResult::Location { .. }))
        .collect()
}

/// Serves every deadline the engine announces for `group`, as a receive
/// plane does.
pub async fn served(session: &SessionManager, group: &GroupId) -> SessionEffects {
    session
        .settle_receive_for_test(group)
        .await
        .expect("the advances run")
}

/// A location `session` seals at the epoch it stands on.
pub async fn sealed_alone(session: &SessionManager, group: &GroupId) -> Event {
    let content = haven_core::location::LocationMessage::new(51.5, -0.12)
        .to_string()
        .expect("a location serializes");
    session
        .send_location(group, content)
        .await
        .expect("the engine seals")
        .publish
        .iter()
        .find_map(|work| match work {
            PublishWork::ApplicationMessage { msg, .. } => {
                SessionManager::transport_message_to_event(msg).ok()
            }
            _ => None,
        })
        .expect("a sealed location")
}

/// Confirms `pending` so that the confirm's transaction lands and the engine
/// goes no further — the write right after it is failed — and returns the
/// member as the dying process leaves it: what a kill between the
/// transaction and the replay leaves in the store (v0.10.4
/// `cgka-engine/src/publish.rs` 120-257, 260, 360). `reached` is the epoch
/// the commit leads to.
pub async fn confirm_and_die(
    member: CircleMember,
    pending: PendingStateRef,
    reached: u64,
) -> CircleMember {
    let (db, key) = mls_db(member.dir.path());
    set_epoch_anchor_write_fault_for_test(&db, &key, reached, true).expect("arm");
    let confirmed = member.session().confirm_published(pending).await;
    set_epoch_anchor_write_fault_for_test(&db, &key, reached, false).expect("disarm");
    assert!(confirmed.is_err(), "premise: the confirm ended on an error");
    member
}

/// Promotes the circle's second member to admin; every member applies it.
pub async fn co_admin(fx: &CircleFixture) {
    let (first, second) = (&fx.members[0], &fx.members[1]);
    let effects = first
        .session()
        .update_admin_policy(
            &fx.group,
            &[
                first.keys.public_key().to_bytes(),
                second.keys.public_key().to_bytes(),
            ],
        )
        .await
        .expect("the promotion is staged");
    let (event, pending) = staged(&effects);
    first
        .session()
        .confirm_published(pending)
        .await
        .expect("the promotion is confirmed");
    for member in &fx.members[1..] {
        member
            .session()
            .process_event_settled_for_test(&event)
            .await
            .expect("each member applies the promotion");
    }
}

/// The circle's admin, holding `fixes` stranded: each sealed by a different
/// other member, in order, parked behind a relay change of the admin's that
/// was then confirmed with its transaction landing and nothing after it.
/// Returns the admin as that process leaves it, the others, the circle, the
/// epoch the commit left, and the fixes.
pub async fn fixes_stranded_by_a_confirm(
    fixes: usize,
) -> (CircleMember, Vec<CircleMember>, GroupId, u64, Vec<Event>) {
    let fx = super::setup_circle(fixes + 1, &[ONE]).await;
    let (admin, others, group) = split(fx);
    let source = epoch(&admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let mut parked = Vec::new();
    for (index, sender) in others.iter().enumerate() {
        let fix = super::drive::sealed_by(sender, &group, latitude_of(index)).await;
        assert!(parks(admin.session(), &fix).await, "premise: parked unread");
        parked.push(fix);
    }
    let admin = confirm_and_die(admin, pending, source + 1).await;
    (admin, others, group, source, parked)
}

/// The latitude the `index`th stranded fix was sealed at.
pub const fn latitude_of(index: usize) -> f64 {
    #[allow(clippy::cast_precision_loss)]
    (index as f64).mul_add(0.25, 48.0)
}

/// `size` new members in the order of their keys, lowest first when `rising`.
fn by_key(size: usize, rising: bool) -> Vec<CircleMember> {
    let mut members: Vec<CircleMember> = (0..size).map(|_| CircleMember::new()).collect();
    members.sort_by_key(|member| member.keys.public_key().to_bytes());
    if !rising {
        members.reverse();
    }
    members
}

/// A circle of three with two admins, in which one admin's commit and the
/// other's were made from the same epoch, the rival's arrived while this
/// device's was pending, and a kill after the confirm's transaction stranded
/// it. Which of two commits from one epoch a circle keeps is decided by
/// their committers' keys, so the caller says which key is the lower.
/// Returns the stranded device as the dying process left it, the rival's
/// device, the circle and the epoch both commits left.
pub async fn a_stranded_rival(
    stranded_is_lower: bool,
) -> (CircleMember, CircleMember, GroupId, u64) {
    let fx = super::setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let group = fx.group.clone();
    let mut members = fx.members;
    let third = members.remove(2);
    let mut rival = members.remove(1);
    let mut stranded = members.remove(0);
    if (stranded.keys.public_key().to_bytes() < rival.keys.public_key().to_bytes())
        != stranded_is_lower
    {
        std::mem::swap(&mut stranded, &mut rival);
    }
    let source = epoch(&stranded, &group).await;
    let (mine, pending) = stage_relays(stranded.session(), &group, &[ONE, TWO]).await;
    let (theirs, their_pending) = stage_relays(rival.session(), &group, &[ONE, THREE]).await;
    rival
        .session()
        .confirm_published(their_pending)
        .await
        .expect("the rival is confirmed");
    assert!(
        parks(stranded.session(), &theirs).await,
        "premise: parked unread"
    );
    for event in [&theirs, &mine] {
        third
            .session()
            .process_event_settled_for_test(event)
            .await
            .expect("the third member is handed both commits");
    }
    rival
        .session()
        .process_event_settled_for_test(&mine)
        .await
        .expect("the rival's device is handed this device's commit");
    assert_eq!(
        third.session().group_relays(&group).await.expect("relays"),
        rival.session().group_relays(&group).await.expect("relays"),
        "premise: the rest of the circle is on one branch",
    );
    let stranded = confirm_and_die(stranded, pending, source + 1).await;
    (stranded, rival, group, source)
}

/// A circle of three whose admin's commit the others applied, whose third
/// member then proposed its leave, and whose admin was handed that leave
/// while its own commit was still pending and stranded it by a kill after
/// the confirm's transaction. The second member then commits the eviction.
/// Returns the admin as the dying process left it, the others, the circle,
/// the epoch the admin's commit left, and the eviction.
///
/// `admin_is_lower` says whose key is the lower, the admin's or the
/// committer's: it decides which of two commits from one epoch a circle
/// keeps, so it matters to a caller that goes on to make the admin commit an
/// eviction of its own, and to no other.
pub async fn a_stranded_leave(
    admin_is_lower: bool,
) -> (CircleMember, Vec<CircleMember>, GroupId, u64, Event) {
    a_stranded_leave_behind(admin_is_lower, 0).await
}

/// [`a_stranded_leave`] with `ahead` fixes of the second member stranded
/// ahead of the leave: they arrived first.
pub async fn a_stranded_leave_behind(
    admin_is_lower: bool,
    ahead: usize,
) -> (CircleMember, Vec<CircleMember>, GroupId, u64, Event) {
    let fx = super::setup_circle_of(by_key(3, admin_is_lower), &[ONE]).await;
    let source = epoch(fx.admin(), &fx.group).await;
    let (mine, pending) = stage_relays(fx.admin().session(), &fx.group, &[ONE, TWO]).await;
    for member in &fx.members[1..] {
        member
            .session()
            .process_event_settled_for_test(&mine)
            .await
            .expect("the circle applies this device's commit");
    }
    for index in 0..ahead {
        let fix = sealed_by(&fx.members[1], &fx.group, latitude_of(index)).await;
        assert!(
            parks(fx.admin().session(), &fix).await,
            "premise: parked unread"
        );
    }
    let leave = leave_of(&fx, 2).await;
    let (admin, others, group) = split(fx);
    assert!(
        parks(admin.session(), &leave).await,
        "premise: parked unread"
    );
    let admin = confirm_and_die(admin, pending, source + 1).await;

    let committer = &others[0];
    assert!(matches!(
        answer(committer.session(), &leave).await,
        IngestOutcome::Processed
    ));
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
    assert_eq!(epoch(committer, &group).await, source + 2, "premise");
    (admin, others, group, source, eviction)
}

/// As [`fixes_stranded_by_a_confirm`], by a ROLLBACK whose transaction
/// landed and whose replay failed at its first write: the rows carry the
/// epoch the circle is still at.
pub async fn fixes_stranded_by_a_rollback(
    fixes: usize,
) -> (CircleMember, Vec<CircleMember>, GroupId, u64, Vec<Event>) {
    fixes_stranded_by_a_rollback_on(ONE, fixes).await
}

/// [`fixes_stranded_by_a_rollback`] in a circle whose one relay is `relay`.
pub async fn fixes_stranded_by_a_rollback_on(
    relay: &str,
    fixes: usize,
) -> (CircleMember, Vec<CircleMember>, GroupId, u64, Vec<Event>) {
    use haven_core::nostr::mls::storage::set_new_stored_message_fault_for_test;

    let fx = super::setup_circle(fixes + 1, &[relay]).await;
    let (admin, others, group) = split(fx);
    let (db, key) = mls_db(admin.dir.path());
    let source = epoch(&admin, &group).await;
    let (_, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    let mut parked = Vec::new();
    for (index, sender) in others.iter().enumerate() {
        let fix = super::drive::sealed_by(sender, &group, latitude_of(index)).await;
        assert!(parks(admin.session(), &fix).await, "premise: parked unread");
        parked.push(fix);
    }
    set_new_stored_message_fault_for_test(&db, &key, true).expect("arm");
    let rolled = admin.session().publish_failed(pending).await;
    set_new_stored_message_fault_for_test(&db, &key, false).expect("disarm");
    assert!(rolled.is_err(), "premise: the rollback ended on an error");
    (admin, others, group, source, parked)
}

/// A circle of three with two admins in which the co-admin removed the
/// third member at the epoch after the first admin's own commit, which the
/// circle had applied and the first admin had not yet confirmed: the removal
/// arrived while that commit was pending and a kill after the confirm's
/// transaction stranded it. Returns the first admin as the dying process
/// left it, the co-admin, the removed member, the circle, the epoch the
/// first commit left, and the removal.
///
/// `admin_is_lower` says whose key is the lower, the first admin's or the
/// co-admin's, for a caller that goes on to make the first admin commit
/// again from the epoch the removal was made at.
pub async fn a_stranded_removal(
    admin_is_lower: bool,
) -> (
    CircleMember,
    CircleMember,
    CircleMember,
    GroupId,
    u64,
    Event,
) {
    let (admin, peer, removed, group, source, pending, theirs, _, _) =
        a_parked_removal(admin_is_lower, None, 0).await;
    let admin = confirm_and_die(admin, pending, source + 1).await;
    (admin, peer, removed, group, source, theirs)
}

/// [`a_stranded_removal`] behind `flood` events of an outsider's that
/// nothing opens, which arrived first, on a device whose engine has no room
/// left for what it cannot open: handed back, each is refused. Returns the
/// first admin as the dying process left it, the co-admin, the removed
/// member, the circle, the epoch the first commit left, and the outsider's
/// events.
pub async fn a_stranded_removal_behind_a_flood(
    flood: usize,
) -> (
    CircleMember,
    CircleMember,
    CircleMember,
    GroupId,
    u64,
    Vec<Event>,
) {
    let (admin, peer, removed, group, source, pending, _, _, forged) =
        a_parked_removal(true, None, flood).await;
    let admin = confirm_and_die(admin, pending, source + 1).await;
    (admin, peer, removed, group, source, forged)
}

/// [`a_stranded_removal`] stranded in a process that goes on running: the
/// first admin's confirm lands and its replay ends on an error at a fix
/// parked ahead of the removal, which leaves the removal parked in a circle
/// that holds nothing pending. Returns the first admin, the co-admin, the
/// removed member and the circle.
pub async fn a_removal_a_running_process_stranded(
) -> (CircleMember, CircleMember, CircleMember, GroupId) {
    let (admin, peer, removed, group, _, pending, _, struck, _) =
        a_parked_removal(true, Some(48.25), 0).await;
    let (db, key) = mls_db(admin.dir.path());
    let struck = struck.expect("a fix was asked for");
    set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), true)
        .expect("arm");
    let confirmed = admin.session().confirm_published(pending).await;
    set_stored_message_write_fault_naming_for_test(&db, &key, struck.id.as_bytes(), false)
        .expect("disarm");
    assert!(confirmed.is_err(), "premise: the replay ended on an error");
    (admin, peer, removed, group)
}

/// The circle of [`a_stranded_removal`] with the first admin's commit still
/// pending and the co-admin's removal parked behind it — behind a fix the
/// co-admin sealed at `ahead`, when one is asked for. Returns the first
/// admin, the co-admin, the removed member, the circle, the epoch the first
/// admin's commit leaves, that commit's pending state, the removal, the fix,
/// and — with `flood` — that many events of an outsider's that nothing opens,
/// parked ahead of the removal on a device whose deferral store was filled
/// first.
async fn a_parked_removal(
    admin_is_lower: bool,
    ahead: Option<f64>,
    flood: usize,
) -> (
    CircleMember,
    CircleMember,
    CircleMember,
    GroupId,
    u64,
    PendingStateRef,
    Event,
    Option<Event>,
    Vec<Event>,
) {
    let fx = super::setup_circle_of(by_key(3, admin_is_lower), &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let removed = others.remove(1);
    let peer = others.remove(0);
    let source = epoch(&admin, &group).await;
    let like = sealed_by(&peer, &group, 0.5).await;
    if flood > 0 {
        fill_the_deferral_store(&admin, &group, &like).await;
    }
    let (mine, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    for member in [&peer, &removed] {
        member
            .session()
            .process_event_settled_for_test(&mine)
            .await
            .expect("the circle applies this device's commit");
    }
    let mut forged = Vec::new();
    for index in 0..flood {
        let envelope = unopenable(&like, 1_000_000 + u32::try_from(index).expect("small"));
        assert!(
            parks(admin.session(), &envelope).await,
            "premise: parked unread"
        );
        forged.push(envelope);
    }
    let mut struck = None;
    if let Some(latitude) = ahead {
        let fix = sealed_by(&peer, &group, latitude).await;
        assert!(parks(admin.session(), &fix).await, "premise: parked unread");
        struck = Some(fix);
    }
    let removal = peer
        .session()
        .remove_members(&group, &[removed.pubkey_hex()])
        .await
        .expect("the co-admin removes the third member");
    let (theirs, their_pending) = staged(&removal);
    peer.session()
        .confirm_published(their_pending)
        .await
        .expect("and confirms it");
    assert!(
        parks(admin.session(), &theirs).await,
        "premise: a peer's commit is parked unread like anything else",
    );
    (
        admin, peer, removed, group, source, pending, theirs, struck, forged,
    )
}

/// The latitude of the fix [`a_fix_from_an_epoch_not_reached_stranded`] strands.
pub const LATER: f64 = 21.5;

/// A circle of three with two admins whose first admin holds stranded a fix
/// the co-admin sealed AFTER removing the third member — an epoch this
/// device has not reached, the removal itself never having been handed to
/// it. Returns the first admin as its process left it, the co-admin, the
/// circle, the epoch the first admin's commit left, and the removal.
///
/// Without `no_room_to_defer`, the first admin's confirm lands and the
/// process dies before the replay. With it, as many envelopes nothing opens
/// as the engine's deferral store holds for a circle are parked ahead of the
/// fix and the confirm runs whole: its replay fills the store with them and
/// has no room left for the fix, which it leaves as it arrived (v0.10.4
/// `message_processor/mod.rs` 3634-3655), so the engine can hold nothing more
/// for the circle that it cannot open. The store is filled behind the
/// commit, never before it: a change staged over a full store passes MDK's
/// foreground preflight, which reads every row's metadata against a 250 ms
/// wall clock and queues the change when the read alone overruns it
/// (`mod.rs` 1177-1232, 1983-2004).
pub async fn a_fix_from_an_epoch_not_reached_stranded(
    no_room_to_defer: bool,
) -> (CircleMember, CircleMember, GroupId, u64, Event) {
    let fx = super::setup_circle(3, &[ONE]).await;
    co_admin(&fx).await;
    let (admin, mut others, group) = split(fx);
    let removed = others.remove(1);
    let peer = others.remove(0);
    let like = if no_room_to_defer {
        Some(sealed_by(&peer, &group, 0.5).await)
    } else {
        None
    };
    let source = epoch(&admin, &group).await;
    let (mine, pending) = stage_relays(admin.session(), &group, &[ONE, TWO]).await;
    for member in [&peer, &removed] {
        member
            .session()
            .process_event_settled_for_test(&mine)
            .await
            .expect("the circle applies this device's commit");
    }
    let removal = peer
        .session()
        .remove_members(&group, &[removed.pubkey_hex()])
        .await
        .expect("the co-admin removes the third member");
    let (theirs, their_pending) = staged(&removal);
    peer.session()
        .confirm_published(their_pending)
        .await
        .expect("and confirms it");
    if let Some(like) = &like {
        for index in 0..MAX_PEEL_DEFERRED_ROWS_PER_GROUP {
            let envelope = unopenable(like, u32::try_from(index).expect("small"));
            assert!(
                parks(admin.session(), &envelope).await,
                "premise: parked unread"
            );
        }
    }
    let later = sealed_by(&peer, &group, LATER).await;
    assert!(
        parks(admin.session(), &later).await,
        "premise: parked unread"
    );
    if !no_room_to_defer {
        let admin = confirm_and_die(admin, pending, source + 1).await;
        return (admin, peer, group, source, theirs);
    }
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the confirm completes");
    assert_eq!(
        unopened_retryable(&held(admin.session(), &group).await),
        1,
        "premise: the confirm's replay filled the deferral store with what nothing opens and \
         left the fix, alone, as it arrived",
    );
    (admin, peer, group, source, theirs)
}

/// An envelope addressed and tagged as `like` is, signed by a key of its own,
/// which nothing opens: what anyone who knows a circle's routing tag can
/// send it. `index` makes it one of its own.
pub fn unopenable(like: &Event, index: u32) -> Event {
    unopenable_at(like, index, Timestamp::now())
}

/// [`unopenable`], dated `at`.
pub fn unopenable_at(like: &Event, index: u32, at: Timestamp) -> Event {
    let content = base64::engine::general_purpose::STANDARD.encode(index.to_be_bytes().repeat(24));
    EventBuilder::new(like.kind, content)
        .tags(like.tags.iter().cloned())
        .custom_created_at(at)
        .sign_with_keys(&Keys::generate())
        .expect("sign")
}

/// Hands `member` envelopes addressed as `like` is, which nothing opens,
/// until the engine refuses one: its deferral store for that circle is full.
/// Each is then given its try, so that the engine's preflight — which queues
/// a change while rows are untried — lets the next change be staged.
pub async fn fill_the_deferral_store(member: &CircleMember, group: &GroupId, like: &Event) {
    for index in 0_u32.. {
        assert!(
            index <= 4 * 2048,
            "the deferral store never filled: the engine's per-group cap is gone"
        );
        let envelope = unopenable(like, index);
        match answer(member.session(), &envelope).await {
            IngestOutcome::TransportDeferred { .. } => {}
            IngestOutcome::ResourceRefused { .. } => break,
            _ => panic!("an envelope nothing opens is deferred or refused"),
        }
    }
    while member
        .session()
        .drain_deferred_peels(group, None)
        .await
        .expect("the drain runs")
        .is_some()
    {}
}
