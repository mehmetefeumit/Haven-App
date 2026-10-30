//! Fixtures for tests of the fanout driver's receive and send entries.
//!
//! Real MDK engines; the fanout transport is scripted and the publisher of
//! what has no record only records, so nothing is dialled. Every instant the
//! driver reads comes from [`ManualClock`]; the only real time a test pays is
//! the engine's own announced deadline where a received commit or proposal
//! has to be applied (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{
    EpochState, FanoutProbe, GroupId, LocationMessageResult, PendingStateRef,
};
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::fanout::{DriveMode, FanoutClock, ModeSource, Publishing};
use nostr::Event;
use tokio::sync::Notify;

use super::{CircleFixture, CircleMember};

/// A mode that is full until it is read with the engine held for the
/// `after`-th time more, and finish-only — its lifecycle over — from that
/// read on: a pause that lands while a pass waits for the engine.
pub struct NarrowsWhenHeld<'a> {
    member: &'a CircleMember,
    after: AtomicU64,
    narrowed: std::sync::atomic::AtomicBool,
}

impl<'a> NarrowsWhenHeld<'a> {
    pub const fn after(member: &'a CircleMember, held_reads: u64) -> Self {
        Self {
            member,
            after: AtomicU64::new(held_reads),
            narrowed: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Whether the read that ends the foreground has been made.
    pub fn narrowed(&self) -> bool {
        self.narrowed.load(Ordering::SeqCst)
    }
}

impl ModeSource for NarrowsWhenHeld<'_> {
    fn mode(&self) -> DriveMode {
        if self.member.session().session_is_held_for_test()
            && self
                .after
                .try_update(Ordering::SeqCst, Ordering::SeqCst, |left| {
                    left.checked_sub(1)
                })
                .is_err()
        {
            self.narrowed.store(true, Ordering::SeqCst);
        }
        if self.narrowed.load(Ordering::SeqCst) {
            DriveMode::FinishOnly
        } else {
            DriveMode::Full
        }
    }

    fn stands(&self) -> bool {
        !self.narrowed.load(Ordering::SeqCst)
    }
}

pub const SECOND_MS: u64 = 1_000;
pub const MINUTE_MS: u64 = 60 * SECOND_MS;
pub const HOUR_MS: u64 = 60 * MINUTE_MS;

/// The driver's clock, set by the test. A wait on it ends when the test
/// moves it there, never by itself.
pub struct ManualClock {
    now: AtomicU64,
    moved: Notify,
}

impl ManualClock {
    pub const ORIGIN: u64 = 1_700_000_000_000;

    pub fn at(offset_ms: u64) -> Arc<Self> {
        Arc::new(Self {
            now: AtomicU64::new(Self::ORIGIN + offset_ms),
            moved: Notify::new(),
        })
    }

    pub fn set(&self, offset_ms: u64) {
        self.now.store(Self::ORIGIN + offset_ms, Ordering::SeqCst);
        self.moved.notify_waiters();
    }
}

impl FanoutClock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }

    fn until<'a>(&'a self, at_ms: u64) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        Box::pin(async move {
            loop {
                let moved = self.moved.notified();
                if self.now_ms() >= at_ms {
                    return;
                }
                moved.await;
            }
        })
    }
}

/// The publisher of what has no record: it keeps what it is handed, with the
/// relays it was handed it for, and answers as told.
pub struct Recorder {
    acks: bool,
    handed: Mutex<Vec<(Event, Vec<String>)>>,
}

impl Recorder {
    pub const fn acking(acks: bool) -> Self {
        Self {
            acks,
            handed: Mutex::new(Vec::new()),
        }
    }

    pub fn handed(&self) -> Vec<(Event, Vec<String>)> {
        self.handed.lock().expect("recorder").clone()
    }
}

impl UnrecordedPublisher for Recorder {
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.handed
                .lock()
                .expect("recorder")
                .push((event.clone(), relays.to_vec()));
            self.acks
        })
    }
}

/// A driver over the scripted transport, with no wake budget of its own.
pub fn through<'a>(
    fanout: &'a ScriptedFanout,
    publisher: &'a Recorder,
    clock: &'a ManualClock,
    mode: &'a dyn ModeSource,
) -> Publishing<'a, ScriptedFanout> {
    Publishing {
        fanout,
        publisher,
        clock,
        deadline_ms: None,
        mode,
    }
}

/// [`through`], inside a wake that ends `room_ms` from now on `clock`.
pub fn within<'a>(
    fanout: &'a ScriptedFanout,
    publisher: &'a Recorder,
    clock: &'a ManualClock,
    mode: &'a dyn ModeSource,
    room_ms: u64,
) -> Publishing<'a, ScriptedFanout> {
    Publishing {
        deadline_ms: Some(clock.now_ms() + room_ms),
        ..through(fanout, publisher, clock, mode)
    }
}

pub async fn ngid(member: &CircleMember, group: &GroupId) -> [u8; 32] {
    member
        .circle
        .get_circle(group)
        .await
        .expect("the circle store is read")
        .expect("the circle exists")
        .circle
        .nostr_group_id
}

pub async fn roster(member: &CircleMember, group: &GroupId) -> Vec<String> {
    member
        .session()
        .member_pubkeys(group)
        .await
        .expect("roster")
}

pub async fn epoch(member: &CircleMember, group: &GroupId) -> u64 {
    member.session().epoch(group).await.expect("epoch")
}

pub async fn records_of(member: &CircleMember, group: &GroupId) -> Vec<FanoutProbe> {
    let mut records = Vec::new();
    for id in member
        .session()
        .fanout_ids_for_test(group)
        .await
        .expect("the store is read")
    {
        records.extend(
            member
                .session()
                .fanout_probe_for_test(&id)
                .await
                .expect("the store is read"),
        );
    }
    records
}

pub async fn staged_ref(member: &CircleMember, group: &GroupId) -> Option<PendingStateRef> {
    match member.session().epoch_state(group).await {
        Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
        _ => None,
    }
}

/// A location `sender` seals the legacy way, at the epoch it stands on.
pub async fn sealed_by(sender: &CircleMember, group: &GroupId, latitude: f64) -> Event {
    sender
        .circle
        .seal_location_for_test(group, &LocationMessage::new(latitude, 2.0))
        .await
        .expect("the member seals a location")
        .0
}

/// A location `sender` seals as the foreground sends one: through the
/// driver in the full mode, no relay taken. A call answered held by stranded
/// input the hand-back has not reached is made again at once, as the driver
/// asks (`retry_after_ms` zero), for as many calls as the engine's store can
/// hold rows to hand back.
pub async fn sealed_in_front_by(sender: &CircleMember, group: &GroupId, latitude: f64) -> Event {
    use haven_core::relay::fanout::{scripted::Inert, LocationSeal, SendHeld, WallClock};
    let publishing: Publishing<'_, Inert> = Publishing {
        fanout: &Inert,
        publisher: &Inert,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    for _ in 0..=2048 / haven_core::nostr::mls::HAND_BACK_WHOLE {
        match publishing
            .seal_location(&sender.circle, group, &LocationMessage::new(latitude, 2.0))
            .await
            .expect("the member seals a location")
            .seal
        {
            LocationSeal::Sealed { event, .. } => return *event,
            LocationSeal::Deferred(SendHeld::StoredInput) => {}
            LocationSeal::Deferred(held) => panic!("the member's send was held: {held:?}"),
        }
    }
    panic!("the member's send was still held by stranded input")
}

/// Whether `results` carry a location `sender` sealed at `latitude`.
pub fn has_fix(results: &[LocationMessageResult], sender: &CircleMember, latitude: f64) -> bool {
    let wanted = format!("{latitude}");
    results.iter().any(|result| {
        matches!(
            result,
            LocationMessageResult::Location { sender_pubkey, content, .. }
                if *sender_pubkey == sender.pubkey_hex() && content.contains(&wanted)
        )
    })
}

/// Whether `member`'s last-known store holds a fix `sender` sealed at
/// `latitude`.
pub async fn stored_fix(
    member: &CircleMember,
    group: &GroupId,
    sender: &CircleMember,
    latitude: f64,
) -> bool {
    let id = ngid(member, group).await;
    member
        .circle
        .snapshot_last_known_for_circle(&id, chrono::Utc::now().timestamp())
        .expect("the store is read")
        .iter()
        .any(|row| {
            row.sender_pubkey == sender.pubkey_hex() && (row.latitude - latitude).abs() < 1e-9
        })
}

/// When `member`'s circle last had a peer's fix arrive.
pub async fn arrived_at(member: &CircleMember, group: &GroupId) -> Option<i64> {
    let id = ngid(member, group).await;
    member
        .circle
        .circle_health(&id)
        .expect("the stamp is read")
        .last_peer_event_at_ms
}

/// Whether `reader` reads the location `event` carries, the legacy way.
pub async fn reads(reader: &CircleMember, event: &Event) -> bool {
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

/// Waits until the deadline the engine announces for `member`'s circle — the
/// eviction's when one is scheduled, else the convergence pass's — is one the
/// engine itself reads as due, or it announces none. The engine's clock
/// cannot be set (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK), so the
/// engine is asked again after each wait it announces: its own answer ends
/// the wait, never a margin of the test's choosing.
pub async fn wait_out_the_engine(member: &CircleMember, group: &GroupId) {
    for _ in 0..1_000 {
        let announced = match member.session().eviction_due_after_for_test(group).await {
            Some(wait) => Some(wait),
            None => member.session().receive_retick_after(group).await,
        };
        match announced {
            Some(wait) if !wait.is_zero() => tokio::time::sleep(wait).await,
            _ => return,
        }
    }
    panic!("the engine never read the deadline it announced as due");
}

/// `fx`'s member `leaver` proposes its leave.
pub async fn leave_of(fx: &CircleFixture, leaver: usize) -> Event {
    fx.members[leaver]
        .circle
        .propose_leave(&fx.group)
        .await
        .expect("the member proposes its leave")
        .expect("a first leave in this epoch proposes")
}

/// Has `admin` take `leave` and then fixes of `witness` through a finish-only
/// poll until the eviction of the member who left is due: nothing is staged,
/// recorded or sent on the way.
pub async fn make_a_departure_due(
    admin: &CircleMember,
    witness: &CircleMember,
    group: &GroupId,
    leave: &Event,
) {
    let transport = ScriptedFanout::default();
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let mode = DriveMode::FinishOnly;
    let finish_only = within(&transport, &outbox, &clock, &mode, HOUR_MS);
    let _ = finish_only
        .ingest_for_poll(&admin.circle, leave)
        .await
        .expect("the leave is ingested");
    for tick in 0..4_u32 {
        wait_out_the_engine(admin, group).await;
        let fix = sealed_by(witness, group, f64::from(tick).mul_add(0.25, 20.0)).await;
        let _ = finish_only
            .ingest_for_poll(&admin.circle, &fix)
            .await
            .expect("a polled fix is ingested");
    }
    wait_out_the_engine(admin, group).await;
    assert!(
        transport.calls().is_empty()
            && outbox.handed().is_empty()
            && staged_ref(admin, group).await.is_none()
            && admin
                .session()
                .eviction_due_after_for_test(group)
                .await
                .is_some(),
        "premise: the eviction is due and nothing was made of it",
    );
}

/// The id of the commit `member` most recently stored for `group`, its own
/// included. Staging a commit writes one, and undoing it leaves that row
/// behind: an unchanged answer says nothing was staged in between.
pub async fn newest_commit_row(member: &CircleMember, group: &GroupId) -> Option<Vec<u8>> {
    member
        .session()
        .stored_convergence_input_for_test(
            group,
            haven_core::nostr::mls::types::OpenMlsContentKind::Commit,
            0,
        )
        .await
        .ok()
        .map(|record| record.id.as_slice().to_vec())
}

/// Has `member` take a leave and the eviction that commits it, in that
/// order and with no advance between them, and apply the eviction.
pub async fn follows_the_eviction(member: &CircleMember, leave: &Event, eviction: &Event) {
    member
        .session()
        .process_event(leave)
        .await
        .expect("the leave is ingested");
    member
        .session()
        .process_event_settled_for_test(eviction)
        .await
        .expect("the eviction is ingested");
}

/// `admin` disbands `group`: the request, the commit the engine's next
/// advance stages for it, confirmed as a relay's acknowledgement would, and
/// the advance that settles it once the engine's own deadline for it has
/// come (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK: real time, as
/// the engine announces it). Every circle already requires the lifecycle
/// component, so nothing has to enable disbanding first. The disband commit
/// is handed back, for the other members to take in.
pub async fn disband(admin: &CircleMember, group: &GroupId) -> Event {
    use haven_core::nostr::mls::types::SendIntent;
    let requested = admin
        .session()
        .send(SendIntent::Disband {
            group_id: group.clone(),
        })
        .await
        .expect("the disband is asked for");
    let staged = match super::stranded::try_staged(&requested) {
        Some(staged) => staged,
        None => super::stranded::staged(
            &admin
                .session()
                .advance_convergence(group)
                .await
                .expect("the advance runs"),
        ),
    };
    let _ = admin
        .session()
        .confirm_published(staged.1)
        .await
        .expect("confirmed");
    for _ in 0..4 {
        if admin
            .session()
            .group_record(group)
            .await
            .is_ok_and(|record| record.disbanded.is_some())
        {
            return staged.0;
        }
        wait_out_the_engine(admin, group).await;
        let _ = admin.session().advance_convergence(group).await;
    }
    panic!("premise: the circle was disbanded");
}

/// Has `member` take in the disband `commit` and settle it once the
/// engine's own deadline for it has come, as [`disband`] does for its admin.
pub async fn take_in_disband(member: &CircleMember, group: &GroupId, commit: &Event) {
    let _ = member
        .session()
        .process_event_settled_for_test(commit)
        .await;
    for _ in 0..4 {
        if member.session().disbanded(group).await {
            return;
        }
        wait_out_the_engine(member, group).await;
        let _ = member.session().advance_convergence(group).await;
    }
    panic!("premise: the member settled the disband");
}
