//! The live plane on the durable fanout driver, in the foreground (Security
//! Rule 13).
//!
//! While a session is in the foreground — a caller has claimed that the
//! app's lifecycle reads `resumed` — its receive engine records every commit
//! and proposal it surfaces as a durable fanout, in the hold that
//! staged it, and a drive sends each through the fanout transport — never on
//! the engine's own client. A session that has only been started and a
//! background burst make no commit of their own: they only finish what is
//! already recorded. A pause touches no stored record.
//!
//! Real MDK engines over `SQLCipher` stores; "a kill" is the manager dropped
//! and the same stores opened again. The fanout transport is scripted
//! ([`ScriptedFanout`]) and sends nothing, and the driver's clock is the
//! test's. The only real time paid is the engine's own announced deadlines:
//! an eviction falls due on the engine's clock, which nothing can set
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

mod helpers;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleError, CircleManager};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::storage::{set_engine_write_fault_for_test, EngineWrite};
use haven_core::nostr::mls::types::{
    EpochState, FanoutMls, FanoutProbe, FanoutTargetStatus, GroupId, MessageState,
    OpenMlsContentKind, PendingStateRef,
};
use haven_core::nostr::mls::{ChangeNote, StorageConfig};
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::fanout::{
    DriveMode, FanoutClock, FanoutSend, LocationSeal, ModeSource, Publishing, SendHeld,
};
use haven_core::relay::live_sync::{
    CircleSpec, Claim, EngineProcessor, EventBus, GroupProcessOutcome, HealthAction, Lifecycle,
    LiveDriver, LiveSyncCore, LiveSyncEvent,
};
use haven_core::relay::retick::MAX_CONVERGENCE_RETICKS;
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use helpers::{
    assert_no_needles, capture_haven_log, capture_haven_log_here, setup_circle, CircleFixture,
    CircleMember,
};
use nostr::{Event, JsonUtil as _, Kind};
use nostr_relay_builder::MockRelay;

const RELAY: &str = "wss://one.live-canary7d2f.example.com";
const OTHER: &str = "wss://two.live-canary7d2f.example.com";

const SECOND_MS: u64 = 1_000;

/// The driver's clock, set by the test.
struct Clock(AtomicU64);

impl Clock {
    const ORIGIN: u64 = 1_700_000_000_000;

    fn at(offset_ms: u64) -> Arc<Self> {
        Arc::new(Self(AtomicU64::new(Self::ORIGIN + offset_ms)))
    }

    fn set(&self, offset_ms: u64) {
        self.0.store(Self::ORIGIN + offset_ms, Ordering::SeqCst);
    }
}

impl FanoutClock for Clock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// A publisher that keeps what it was handed and answers as scripted: the
/// publisher of what has no record, standing in for the drive pool's.
struct Recording {
    acks: bool,
    handed: Mutex<Vec<Event>>,
}

impl Recording {
    fn acking(acks: bool) -> Arc<Self> {
        Arc::new(Self {
            acks,
            handed: Mutex::new(Vec::new()),
        })
    }

    fn handed(&self) -> Vec<Event> {
        self.handed.lock().expect("recording").clone()
    }
}

impl UnrecordedPublisher for Recording {
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a Event,
        _relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.handed.lock().expect("recording").push(event.clone());
            self.acks
        })
    }
}

/// One device's live plane: a processor over its circle manager, with the
/// scripted fanout transport, the publisher of what has no record, the
/// driver's clock and the bus, each kept for the test to read.
struct Plane {
    processor: EngineProcessor,
    transport: Arc<ScriptedFanout>,
    unrecorded: Arc<Recording>,
    clock: Arc<Clock>,
    bus: tokio::sync::broadcast::Receiver<LiveSyncEvent>,
}

impl Plane {
    fn over(circle: &Arc<CircleManager>) -> Self {
        Self::with(circle, Arc::new(ScriptedFanout::default()), Clock::at(0))
    }

    fn with(
        circle: &Arc<CircleManager>,
        transport: Arc<ScriptedFanout>,
        clock: Arc<Clock>,
    ) -> Self {
        let unrecorded = Recording::acking(true);
        let bus = EventBus::new();
        let rx = bus.subscribe();
        let processor = EngineProcessor::with_driver(
            Arc::clone(circle),
            bus,
            LiveDriver {
                fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
                publisher: Arc::clone(&unrecorded) as Arc<dyn UnrecordedPublisher>,
                clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
            },
        );
        Self {
            processor,
            transport,
            unrecorded,
            clock,
            bus: rx,
        }
    }

    /// The locations the bus has carried since it was last read, as
    /// `(sender, content)`.
    fn locations(&mut self) -> Vec<(String, String)> {
        let mut seen = Vec::new();
        while let Ok(event) = self.bus.try_recv() {
            if let LiveSyncEvent::Location {
                sender_pubkey,
                content,
                ..
            } = event
            {
                seen.push((sender_pubkey, content));
            }
        }
        seen
    }
}

async fn ngid(member: &CircleMember, group: &GroupId) -> [u8; 32] {
    member
        .circle
        .get_circle(group)
        .await
        .expect("the circle store is read")
        .expect("the circle exists")
        .circle
        .nostr_group_id
}

async fn roster(member: &CircleMember, group: &GroupId) -> Vec<String> {
    member
        .session()
        .member_pubkeys(group)
        .await
        .expect("roster")
}

async fn records_of(member: &CircleMember, group: &GroupId) -> Vec<FanoutProbe> {
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

/// What a record is, for "nothing touched it": its event's id and bytes,
/// where its commit stands, and each relay's status and attempt count.
type Standing = (
    nostr::EventId,
    Vec<u8>,
    FanoutMls,
    Vec<FanoutTargetStatus>,
    Vec<u32>,
);

async fn standing_of(member: &CircleMember, group: &GroupId) -> Vec<Standing> {
    records_of(member, group)
        .await
        .into_iter()
        .map(|record| {
            (
                record.event_id,
                record.payload,
                record.mls,
                record.statuses,
                record.attempts,
            )
        })
        .collect()
}

async fn staged_ref(member: &CircleMember, group: &GroupId) -> Option<PendingStateRef> {
    match member.session().epoch_state(group).await {
        Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
        _ => None,
    }
}

async fn sealed_by(sender: &CircleMember, group: &GroupId, latitude: f64) -> Event {
    sender
        .circle
        .seal_location_for_test(group, &LocationMessage::new(latitude, 2.0))
        .await
        .expect("the member seals a location")
        .0
}

/// Feeds `leaver`'s leave through `plane` and re-ticks it with fresh peer
/// locations until the eviction is no longer merely due: it is staged (the
/// projected roster drops the leaver).
async fn feed_leave(plane: &Plane, fx: &CircleFixture, leaver: usize, witness: usize) -> Event {
    feed_leave_to(&plane.processor, fx, leaver, witness).await
}

/// [`feed_leave`], through any processor: a plane's, or a session's own.
async fn feed_leave_to(
    processor: &EngineProcessor,
    fx: &CircleFixture,
    leaver: usize,
    witness: usize,
) -> Event {
    let admin = fx.admin();
    let id = ngid(admin, &fx.group).await;
    let proposal = fx.members[leaver]
        .circle
        .propose_leave(&fx.group)
        .await
        .expect("the member proposes its leave")
        .expect("a first leave in this epoch proposes");
    processor.process_group_event(&proposal, &id).await;
    let leaver_hex = fx.members[leaver].pubkey_hex();
    feed_leave_ticks_to(processor, fx, witness, || async {
        !roster(admin, &fx.group).await.contains(&leaver_hex)
    })
    .await;
    proposal
}

/// Re-ticks `plane` with fresh locations from `witness` until `done`. The
/// engine's deadlines for a leave run on its own clock, so each tick waits
/// out the one the engine announces — never a time of this test's choosing,
/// which a loaded machine would outrun — and the ingest that follows serves
/// it.
async fn feed_leave_ticks<F, Fut>(plane: &Plane, fx: &CircleFixture, witness: usize, done: F)
where
    F: Fn() -> Fut,
    Fut: Future<Output = bool>,
{
    feed_leave_ticks_to(&plane.processor, fx, witness, done).await;
}

/// [`feed_leave_ticks`], through any processor.
async fn feed_leave_ticks_to<F, Fut>(
    processor: &EngineProcessor,
    fx: &CircleFixture,
    witness: usize,
    done: F,
) where
    F: Fn() -> Fut,
    Fut: Future<Output = bool>,
{
    let admin = fx.admin();
    let id = ngid(admin, &fx.group).await;
    for tick in 0..12 {
        if done().await {
            return;
        }
        let announced = match admin.session().eviction_due_after_for_test(&fx.group).await {
            Some(wait) => Some(wait),
            None => admin.session().receive_retick_after(&fx.group).await,
        };
        tokio::time::sleep(announced.unwrap_or_default() + Duration::from_millis(5)).await;
        let location = sealed_by(
            &fx.members[witness],
            &fx.group,
            f64::from(tick).mul_add(0.01, 1.0),
        )
        .await;
        processor.process_group_event(&location, &id).await;
    }
    assert!(done().await, "what the ticks were fed for never happened");
}

/// A three-member circle whose admin's live plane is in the foreground and
/// has just recorded the eviction of a member who left: nothing sent yet.
async fn an_eviction_recorded_in_the_foreground(relays: &[&str]) -> (CircleFixture, Plane) {
    let (fx, plane, _leave) = an_eviction_recorded_with_its_leave(relays).await;
    (fx, plane)
}

/// [`an_eviction_recorded_in_the_foreground`], with the leave it commits —
/// and the control every "removal removes" assertion needs: before it left,
/// the member read what the circle sealed.
async fn an_eviction_recorded_with_its_leave(relays: &[&str]) -> (CircleFixture, Plane, Event) {
    let fx = setup_circle(3, relays).await;
    let before = sealed_by(&fx.members[2], &fx.group, 0.5).await;
    assert!(
        helpers::drive::reads(&fx.members[1], &before).await,
        "control: the member reads the circle before it leaves",
    );
    let plane = Plane::over(&fx.admin().circle);
    plane.processor.for_test().set_background_burst(false);
    let leave = feed_leave(&plane, &fx, 1, 2).await;
    (fx, plane, leave)
}

/// The removal removes: the remaining member applies the driven eviction and
/// reads what the admin seals afterwards; the member who left does not.
async fn assert_the_eviction_removed(
    admin: &CircleMember,
    witness: &CircleMember,
    leaver: &CircleMember,
    group: &GroupId,
    leave: &Event,
    eviction: &Event,
) {
    helpers::drive::follows_the_eviction(witness, leave, eviction).await;
    let after = sealed_by(admin, group, 9.5).await;
    assert!(
        helpers::drive::reads(witness, &after).await,
        "the remaining member does not read what is sealed after the eviction",
    );
    assert!(
        !helpers::drive::reads(leaver, &after).await,
        "the member who left reads what is sealed after its eviction",
    );
}

// ── Staging and driving ──────────────────────────────────────────────────────

/// In the foreground the eviction of a member who left is recorded as a
/// durable fanout in the hold that staged it, handed to nobody, and sent by
/// the drive through the fanout transport, and applied on the relay's acknowledgement. The ingest itself sends nothing:
/// no relay call is made until the drive runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_owed_after_a_departure_is_recorded_in_the_foreground_and_sent_by_the_drive() {
    let (fx, plane, leave) = an_eviction_recorded_with_its_leave(&[RELAY]).await;
    let admin = fx.admin();
    let leaver = fx.members[1].pubkey_hex();

    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the eviction has exactly one record"));
    assert_eq!(
        (record.mls, record.targets.as_slice()),
        (FanoutMls::Pending, &[RELAY.to_owned()][..]),
    );
    assert_eq!(
        plane.transport.call_count(),
        0,
        "the ingest worker called a relay: a drive must run off it",
    );
    assert!(staged_ref(admin, &fx.group).await.is_some());

    plane.transport.answer(RELAY, [Answer::Accepted]);
    plane.processor.for_test().drive_due().await;

    let calls = plane.transport.calls();
    assert_eq!(
        calls.len(),
        1,
        "the eviction was not sent once to its relay"
    );
    let eviction = Event::from_json(&calls[0].payload).expect("a signed event");
    assert!(eviction.kind == Kind::Custom(445) && eviction.id == record.event_id);
    assert!(!roster(admin, &fx.group).await.contains(&leaver));
    assert!(staged_ref(admin, &fx.group).await.is_none());
    assert!(
        records_of(admin, &fx.group).await.is_empty(),
        "one relay, one acknowledgement: the record has ended",
    );
    assert!(plane.unrecorded.handed().is_empty());
    assert_the_eviction_removed(
        admin,
        &fx.members[2],
        &fx.members[1],
        &fx.group,
        &leave,
        &eviction,
    )
    .await;
}

/// A processor with no transport still records what it stages in the
/// foreground, hands it to nobody, and leaves the record for a plane that has
/// a transport — which then sends exactly those bytes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_plane_with_no_transport_stages_and_leaves_the_row_for_the_next_plane() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let processor = EngineProcessor::new(Arc::clone(&admin.circle), EventBus::new());
    processor.for_test().set_background_burst(false);
    let plane = Plane {
        processor,
        transport: Arc::new(ScriptedFanout::default()),
        unrecorded: Recording::acking(true),
        clock: Clock::at(0),
        bus: EventBus::new().subscribe(),
    };
    feed_leave(&plane, &fx, 1, 2).await;

    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the eviction has exactly one record"));
    assert_eq!(record.mls, FanoutMls::Pending);
    plane.processor.for_test().drive_due().await;
    let [left] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the record was not left as it was"));
    assert!(left.event_id == record.event_id && left.mls == FanoutMls::Pending);
    assert!(left.attempts.iter().all(|attempts| *attempts == 0));

    // A plane that has a transport.
    plane.transport.answer(RELAY, [Answer::Accepted]);
    let publishing: Publishing<'_, dyn FanoutSend> = Publishing {
        fanout: plane.transport.as_ref(),
        publisher: plane.unrecorded.as_ref(),
        clock: plane.clock.as_ref(),
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let _ = publishing.resume(&admin.circle).await;
    let calls = plane.transport.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].event_id, record.event_id);
    assert!(!roster(admin, &fx.group)
        .await
        .contains(&fx.members[1].pubkey_hex()));
}

/// What a session that has only been started and a background burst make
/// of a departure: nothing at all. The eviction comes due and stays due —
/// nothing staged, nothing recorded, nothing handed to any publisher, and no
/// relay taken — and the session goes on receiving. The foreground that
/// follows makes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_started_session_and_a_burst_make_nothing_of_a_departure() {
    for lifecycle in [Lifecycle::Launched, Lifecycle::Burst] {
        let fx = setup_circle(3, &[RELAY]).await;
        let admin = fx.admin();
        // Caught up, as a sweep or the live plane's end of stored events makes it.
        admin.session().mark_caught_up_for_test(&fx.group);
        let plane = Plane::over(&admin.circle);
        if lifecycle == Lifecycle::Burst {
            plane.processor.for_test().set_background_burst(true);
        }
        assert_eq!(plane.processor.lifecycle(), lifecycle);
        let id = ngid(admin, &fx.group).await;
        let leave = fx.members[1]
            .circle
            .propose_leave(&fx.group)
            .await
            .expect("the member proposes its leave")
            .expect("a first leave in this epoch proposes");
        plane.processor.process_group_event(&leave, &id).await;
        let due = || async {
            admin
                .session()
                .eviction_due_after_for_test(&fx.group)
                .await
                .is_some_and(|wait| wait.is_zero())
        };
        feed_leave_ticks(&plane, &fx, 2, &due).await;
        for tick in 0..3_u32 {
            let fix = sealed_by(
                &fx.members[2],
                &fx.group,
                f64::from(tick).mul_add(0.01, 3.0),
            )
            .await;
            assert_eq!(
                plane.processor.process_group_event(&fix, &id).await,
                GroupProcessOutcome::Applied,
                "{lifecycle:?}: the session stopped receiving while an eviction was due",
            );
            plane.processor.for_test().drive_due().await;
        }
        assert!(
            due().await
                && staged_ref(admin, &fx.group).await.is_none()
                && records_of(admin, &fx.group).await.is_empty()
                && roster(admin, &fx.group).await.len() == 3,
            "{lifecycle:?}: the eviction of a member who left was staged or recorded",
        );
        assert!(
            plane.unrecorded.handed().is_empty() && plane.transport.call_count() == 0,
            "{lifecycle:?}: something was published for a departure, or a relay taken",
        );

        // The foreground that follows makes it, with nothing arriving: its
        // drive gives the circle the full advance, under a record.
        plane.processor.for_test().set_background_burst(false);
        plane.transport.answer(RELAY, [Answer::Accepted]);
        plane.processor.for_test().drive_due().await;
        assert!(
            staged_ref(admin, &fx.group).await.is_none()
                && plane.transport.calls().len() == 1
                && !roster(admin, &fx.group)
                    .await
                    .contains(&fx.members[1].pubkey_hex()),
            "{lifecycle:?}: the next foreground's drive did not make the eviction left due",
        );
    }
}

/// A record stored, sent before and due, met by each lifecycle that is not
/// the foreground. A session only started and a background burst drive it
/// in the mode that only finishes: the same bytes go to the relay that is
/// due and the commit it acknowledges is confirmed — and what is left of the
/// record is the foreground's. A session that has left the foreground and
/// is in no burst drives nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_record_sent_before_and_due_is_finished_by_a_started_session_and_by_a_burst() {
    for lifecycle in [Lifecycle::Launched, Lifecycle::Burst, Lifecycle::Background] {
        let (fx, mut plane) = an_eviction_recorded_in_the_foreground(&[RELAY, OTHER]).await;
        let admin = fx.admin();
        let leaver = fx.members[1].pubkey_hex();
        // Its first send, in the foreground: unanswered by both.
        for relay in [RELAY, OTHER] {
            plane.transport.answer(relay, [Answer::Silent]);
        }
        plane.processor.for_test().drive_due().await;
        let first = plane.transport.calls();
        assert_eq!(first.len(), 2, "premise: sent once to each relay");
        // A peer's fix arrives behind the pending eviction and waits unread.
        let waiting = sealed_by(&fx.members[2], &fx.group, 9.5).await;
        let id = ngid(admin, &fx.group).await;
        assert_eq!(
            plane.processor.process_group_event(&waiting, &id).await,
            GroupProcessOutcome::Buffered,
            "premise: held unread behind the pending commit",
        );
        let _ = plane.locations();
        let before = standing_of(admin, &fx.group).await;

        match lifecycle {
            Lifecycle::Launched => plane.processor.for_test().note_launched(),
            Lifecycle::Burst => plane.processor.for_test().set_background_burst(true),
            _ => plane.processor.for_test().leave_foreground(),
        }
        assert_eq!(plane.processor.lifecycle(), lifecycle);
        plane.clock.set(3_600 * SECOND_MS);
        plane.transport.answer(RELAY, [Answer::Accepted]);
        plane.processor.for_test().drive_due().await;

        let calls = plane.transport.calls();
        if lifecycle == Lifecycle::Background {
            assert!(
                calls.is_empty()
                    && standing_of(admin, &fx.group).await == before
                    && staged_ref(admin, &fx.group).await.is_some(),
                "a session in no burst and out of the foreground drove a stored record",
            );
            continue;
        }
        assert!(
            calls.len() == 2
                && calls
                    .iter()
                    .all(|call| call.event_id == first[0].event_id
                        && call.payload == first[0].payload),
            "the relays that were due were not each sent the same bytes once",
        );
        let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
            .unwrap_or_else(|_| panic!("a drive that only finishes ended or replaced a record"));
        assert!(
            record.mls == FanoutMls::Confirmed
                && staged_ref(admin, &fx.group).await.is_none()
                && !roster(admin, &fx.group).await.contains(&leaver),
            "an acknowledged eviction was not confirmed by a drive that only finishes",
        );
        assert!(
            plane.unrecorded.handed().is_empty(),
            "a drive that only finishes handed something to a publisher, or parked it",
        );
        // What waited behind the commit is replayed by that confirm and
        // reaches the store, the circle's arrival stamp and the bus.
        assert!(
            plane
                .locations()
                .iter()
                .any(|(sender, content)| *sender == fx.members[2].pubkey_hex()
                    && content.contains("9.5"))
                && helpers::drive::stored_fix(admin, &fx.group, &fx.members[2], 9.5).await
                && helpers::drive::arrived_at(admin, &fx.group).await.is_some(),
            "a fix replayed by a finish-only confirm did not reach the store, the arrival \
             stamp and the bus",
        );
        // The relay still owed is the foreground's: asked again in the same
        // lifecycle, the record makes no call.
        plane.clock.set(2 * 3_600 * SECOND_MS);
        plane.processor.for_test().drive_due().await;
        assert_eq!(
            plane.transport.call_count(),
            0,
            "a drive that only finishes went on with an applied commit's record",
        );
    }
}

// ── What a drive hands back ──────────────────────────────────────────────────

/// A peer's fix that waited behind the pending eviction is replayed by the
/// confirm and reaches the same three places an ingested fix does: the
/// last-known store, the circle's "a peer's fix arrived" stamp, and the bus.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fix_replayed_inside_a_live_plane_confirm_reaches_store_liveness_and_the_bus() {
    let (fx, mut plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    let admin = fx.admin();
    let id = ngid(admin, &fx.group).await;
    let witness = &fx.members[2];
    let _ = plane.locations();
    let arrived = || {
        admin
            .circle
            .circle_health(&id)
            .expect("the stamp is read")
            .last_peer_event_at_ms
    };
    let arrived_before = arrived();

    // Sealed at the epoch the eviction leaves, while the eviction is pending:
    // the engine holds it unread.
    let waiting = sealed_by(witness, &fx.group, 48.25).await;
    let outcome = plane.processor.process_group_event(&waiting, &id).await;
    assert_eq!(outcome, GroupProcessOutcome::Buffered);
    assert!(plane.locations().is_empty(), "a held fix reached the bus");

    plane.transport.answer(RELAY, [Answer::Accepted]);
    plane.processor.for_test().drive_due().await;

    let seen = plane.locations();
    assert_eq!(seen.len(), 1, "the replayed fix did not reach the bus once");
    assert_eq!(seen[0].0, witness.pubkey_hex());
    assert!(seen[0].1.contains("48.25"));
    let stored = admin
        .circle
        .snapshot_last_known_for_circle(&id, chrono::Utc::now().timestamp())
        .expect("the store is read");
    assert!(
        stored
            .iter()
            .any(|row| row.sender_pubkey == witness.pubkey_hex()
                && (row.latitude - 48.25).abs() < 1e-9),
        "the replayed fix is not in the last-known store",
    );
    assert!(
        arrived() > arrived_before,
        "the replayed fix did not stamp its circle as one a fix arrived in",
    );
}

/// A relay that never answers leaves the eviction recorded and awaiting:
/// never applied and never rolled back. The drive
/// says when the relay is next due and keeps that for whoever schedules, and
/// a drive before then calls nobody.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unanswered_drive_leaves_the_record_awaiting_and_says_when_it_is_next_due() {
    let (fx, plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    let admin = fx.admin();
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    assert_eq!(plane.processor.drive_retry_after_ms(), None);

    plane.transport.answer(RELAY, [Answer::Silent]);
    plane.processor.for_test().drive_due().await;
    assert_eq!(plane.transport.calls().len(), 1);
    assert_eq!(staged_ref(admin, &fx.group).await, Some(pending));
    assert_eq!(
        plane.processor.drive_retry_after_ms(),
        Some(30 * SECOND_MS),
        "an unanswered relay is due again after MDK's first wait",
    );

    // Asked again at once, and again a second before the relay is due.
    for offset in [0, 29 * SECOND_MS] {
        plane.clock.set(offset);
        plane.processor.for_test().drive_due().await;
        assert_eq!(
            plane.transport.call_count(),
            0,
            "a relay that is not due was called",
        );
    }
    assert_eq!(staged_ref(admin, &fx.group).await, Some(pending));
}

// ── A change the user queued (the one-attempt reservation) ───────────────────

/// A circle of three whose second member is an admin too, has asked for the
/// third to be removed while its sends were gated, and has since caught up
/// on a plane that does not drive: the removal is still queued, the circle's
/// convergence pass has closed, and nothing has given the removal its one
/// attempt. Until something does, this device applies no commit it receives.
struct Reserved {
    alice: CircleMember,
    bob: CircleMember,
    carol: CircleMember,
    group: GroupId,
}

async fn a_removal_left_queued_behind_a_closed_pass() -> Reserved {
    a_change_left_queued_behind_a_closed_pass(true).await
}

/// As above; with `removal` false what is queued is a relay change, which
/// removes nobody.
async fn a_change_left_queued_behind_a_closed_pass(removal: bool) -> Reserved {
    left_queued_behind_a_closed_pass(3, removal).await.0
}

/// A circle of `size` in which Bob has queued one change behind a pass he
/// cannot close: a removal of everybody but Alice and himself — Carol, and
/// whoever comes back beside the circle — or a relay change.
async fn left_queued_behind_a_closed_pass(
    size: usize,
    removal: bool,
) -> (Reserved, Vec<CircleMember>) {
    let fx = setup_circle(size, &[RELAY]).await;
    let group = fx.group.clone();
    let mut members = fx.members;
    let also = members.split_off(3);
    let carol = members.remove(2);
    let bob = members.remove(1);
    let alice = members.remove(0);
    let promote = alice
        .circle
        .admin_handoff_for_test(&group, &bob.keys.public_key())
        .await
        .expect("promote");
    for member in [&bob, &carol].into_iter().chain(&also) {
        member
            .session()
            .process_event_settled_for_test(&promote)
            .await
            .expect("applies the promotion");
    }
    // Alice commits twice; Bob holds only the second, which he cannot chain,
    // so what he asks for is queued until the first reaches him.
    let mut commits = Vec::new();
    let tip_before_second = {
        let first = alice
            .circle
            .update_relays_for_test(&group, &[RELAY.to_string(), OTHER.to_string()])
            .await
            .expect("a relay change");
        commits.push(first);
        alice.circle.group_epoch(&group).await.expect("epoch")
    };
    alice
        .circle
        .update_relays_for_test(&group, &[RELAY.to_string()])
        .await
        .expect("a second relay change");
    let row = alice
        .session()
        .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, tip_before_second)
        .await
        .expect("alice's second commit");
    bob.session()
        .stage_convergence_input_for_test(&row, MessageState::Retryable, 0)
        .await
        .expect("bob holds the commit he cannot chain");
    let asked = if removal {
        let named: Vec<String> = std::iter::once(&carol)
            .chain(&also)
            .map(CircleMember::pubkey_hex)
            .collect();
        bob.session().remove_members(&group, &named).await
    } else {
        bob.session()
            .update_relays(&group, vec![RELAY.to_string(), OTHER.to_string()])
            .await
    };
    assert!(
        asked.is_ok_and(|effects| !effects.queued.is_empty()),
        "premise: the change is queued",
    );
    // Caught up on a plane with no driver.
    let undriven = EngineProcessor::new(Arc::clone(&bob.circle), EventBus::new());
    let id = ngid(&bob, &group).await;
    let _ = undriven.process_group_event(&commits[0], &id).await;
    assert_eq!(
        (
            bob.circle.group_epoch(&group).await.expect("epoch"),
            queue_len(&bob, &group).await
        ),
        (alice.circle.group_epoch(&group).await.expect("epoch"), 1),
        "premise: caught up, and the removal still queued",
    );
    let reserved = Reserved {
        alice,
        bob,
        carol,
        group,
    };
    (reserved, also)
}

async fn queue_len(member: &CircleMember, group: &GroupId) -> usize {
    member
        .session()
        .queued_intent_count_for_test(group)
        .await
        .expect("the queue")
}

/// A change the user queued is given its attempt by the foreground's own
/// drive, with no event arriving in its circle: the drive a foreground open
/// and each health tick ask for advances every circle that holds a queued
/// change, the engine releases the removal, it is recorded in that hold and
/// sent in the same pass. No reservation is left standing in the foreground.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_queued_in_a_quiet_circle_is_given_its_attempt_by_a_foreground_drive() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let plane = Plane::over(&fx.bob.circle);
    plane.transport.answer(RELAY, [Answer::Accepted]);

    // Not in a session that has only been started.
    plane.processor.for_test().drive_due().await;
    assert_eq!(
        (
            queue_len(&fx.bob, &fx.group).await,
            plane.transport.call_count()
        ),
        (1, 0),
        "a session not known to be in the foreground drained the user's queue",
    );
    // Nor in a background burst.
    plane.processor.for_test().set_background_burst(true);
    plane.processor.for_test().drive_due().await;
    assert_eq!(
        (
            queue_len(&fx.bob, &fx.group).await,
            plane.transport.call_count()
        ),
        (1, 0),
        "a background burst drained the user's queue",
    );

    plane.processor.for_test().set_background_burst(false);
    plane.processor.for_test().drive_due().await;

    assert_eq!(
        queue_len(&fx.bob, &fx.group).await,
        0,
        "the queued removal was left standing in the foreground",
    );
    let calls = plane.transport.calls();
    assert_eq!(
        calls.len(),
        1,
        "the released removal was not sent in the same pass"
    );
    assert!(
        !roster(&fx.bob, &fx.group)
            .await
            .contains(&fx.carol.pubkey_hex()),
        "the removal the user asked for was not made",
    );
}

/// A commit the engine RELEASED from its queue is never marked as removing
/// nobody, though this one removes nobody: what it took in by reference on
/// its way out of the queue is not what the roster read before the call can
/// show. So it is never undone for want of a relay, at its bound included.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_released_from_the_queue_is_never_marked_as_removing_nobody() {
    const DAY_MS: u64 = 24 * 3_600 * SECOND_MS;
    let fx = a_change_left_queued_behind_a_closed_pass(false).await;
    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(RELAY, [Answer::Unreachable]);
    let clock = Clock::at(0);
    let plane = Plane::with(&fx.bob.circle, Arc::clone(&transport), Arc::clone(&clock));
    plane.processor.for_test().set_background_burst(false);
    plane.processor.for_test().drive_due().await;
    assert_eq!(
        (queue_len(&fx.bob, &fx.group).await, transport.calls().len()),
        (0, 1),
        "premise: the relay change was released, recorded and sent once",
    );
    assert!(
        !fx.bob.session().commit_removes_nobody_for_test(&fx.group),
        "a commit released from the queue was marked as removing nobody",
    );

    // Past its bound with no relay ever reached: a commit so marked is
    // undone here.
    clock.set(DAY_MS + 3_600 * SECOND_MS);
    transport.answer(RELAY, [Answer::Unreachable]);
    plane.processor.for_test().drive_due().await;
    assert!(
        staged_ref(&fx.bob, &fx.group).await.is_some()
            && fx.bob.session().peek_change_notes(&fx.group).is_empty(),
        "a commit released from the queue was undone at its bound",
    );
}

/// An event that arrives behind a queued change is itself answered with the
/// attempt, in the foreground: the peer's commit is held, its circle owes an
/// advance, and the advance of a plane that drives makes the engine's one
/// attempt and records the removal it releases — in the ingest, with no
/// relay called from it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_arriving_behind_a_queued_change_is_answered_with_its_attempt_in_the_foreground() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(false);
    let next = fx
        .alice
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("alice's next commit");

    let id = ngid(&fx.bob, &fx.group).await;
    let _ = plane.processor.process_group_event(&next, &id).await;

    assert_eq!(
        queue_len(&fx.bob, &fx.group).await,
        0,
        "an event arrived behind the reservation and the reservation still stands",
    );
    let records = records_of(&fx.bob, &fx.group).await;
    assert_eq!(records.len(), 1, "the released removal has no record");
    assert_eq!(records[0].mls, FanoutMls::Pending);
    assert_eq!(
        plane.transport.call_count(),
        0,
        "the ingest worker called a relay",
    );
}

/// A location asked of `member` for `group` by a plane that makes no commit:
/// whether it was sealed, or what it was answered with instead.
async fn seal_finishing(member: &CircleMember, group: &GroupId) -> Result<(), CircleError> {
    member
        .circle
        .seal_location_for_test(group, &LocationMessage::new(51.5, -0.12))
        .await
        .map(|_| ())
}

/// In a background burst an event that arrives behind a queued change does
/// not have the change made — a burst makes no commit — and is not left held
/// behind it for good either: once the queued change is what holds the
/// circle at its epoch it is retired, its circle told, and the peer's commit
/// is applied. Nothing is staged, recorded or sent.
///
/// The change here is a REMOVAL, and the member it names can still read. So
/// it is said as one, durably and without naming anybody in a log, and from
/// then on nothing is sealed for the circle by any call: a location asked
/// for in the burst is deferred, and so is the claimed foreground's own
/// (decision 238). A foreground drive does not end that — the member still
/// reads. It ends when the user has been shown what happened, and the
/// names kept for it — in the circle store, and nowhere else — end with it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::too_many_lines)]
async fn an_event_arriving_behind_a_queued_change_in_a_burst_is_applied_and_the_change_retired() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(true);
    let next = fx
        .alice
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("alice's next commit");

    let id = ngid(&fx.bob, &fx.group).await;
    let lines = capture_haven_log(async {
        let _ = plane.processor.process_group_event(&next, &id).await;
    })
    .await;
    let lines = helpers::haven_core_lines(&lines);
    assert!(
        !lines.is_empty(),
        "premise: retiring a queued change is logged, so the capture is not vacuous",
    );
    assert_no_needles(
        &lines,
        &[
            &fx.carol.pubkey_hex(),
            &fx.bob.pubkey_hex(),
            &hex::encode(fx.group.as_slice()),
            &hex::encode(id),
        ],
    );

    assert_eq!(
        (
            fx.bob.circle.group_epoch(&fx.group).await.expect("epoch"),
            queue_len(&fx.bob, &fx.group).await,
            fx.bob.session().peek_change_notes(&fx.group),
        ),
        (
            fx.alice.circle.group_epoch(&fx.group).await.expect("epoch"),
            0,
            vec![ChangeNote::QueuedRemovalDropped],
        ),
        "a burst left its circle at its epoch behind a change it cannot make, retired the \
         removal with nothing said, or did not say it as a removal",
    );
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ),
        "a location was sealed from the background for a circle whose removal a burst had \
         set aside: the member it named still reads",
    );
    let driven = a_driver(&plane, &DriveMode::FinishOnly)
        .seal_location(
            &fx.bob.circle,
            &fx.group,
            &LocationMessage::new(51.5, -0.12),
        )
        .await
        .expect("the send is answered");
    assert!(
        matches!(driven.seal, LocationSeal::Deferred(SendHeld::RemovalUnmade)),
        "the driver's own send for that circle was sealed, or was not answered with what \
         holds it",
    );
    assert_eq!(
        removal_targets(&fx.bob),
        [fx.carol.pubkey_hex()],
        "who the removal named was not kept with its note",
    );
    assert!(
        roster(&fx.bob, &fx.group)
            .await
            .contains(&fx.carol.pubkey_hex())
            && records_of(&fx.bob, &fx.group).await.is_empty()
            && staged_ref(&fx.bob, &fx.group).await.is_none()
            && plane.transport.call_count() == 0
            && plane.unrecorded.handed().is_empty(),
        "a burst made the queued change, recorded something, or sent something",
    );

    // The foreground: its own sends are held too (decision 238), and its
    // drive ends nothing — the member the removal named still reads. Back
    // in a burst, the hold stands.
    plane.processor.for_test().set_background_burst(false);
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ),
        "a claimed foreground sealed for a circle whose removal was set aside: the member \
         it named still reads",
    );
    plane.processor.for_test().drive_due().await;
    plane.processor.for_test().set_background_burst(true);
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ) && fx.bob.session().peek_change_notes(&fx.group) == [ChangeNote::QueuedRemovalDropped],
        "the hold on background sends ended at a foreground drive, with the member the \
         removal named still in the circle — or the word that it was dropped was lost",
    );
    // With no live plane at all the process says nothing about whether it is
    // in front of its user — on Android the one that shares in the
    // background is such a process — and the hold stands there too.
    drop(plane);
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ),
        "a process with no live plane sealed for a circle whose removal was set aside: the \
         member it named still reads",
    );
    let plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(true);

    // The user is shown what happened: the note ends, and with it the hold
    // and the names kept for it. None of that names anybody in a log.
    let lines = Box::pin(capture_haven_log(async {
        let _ = seal_finishing(&fx.bob, &fx.group).await;
        let shown = fx.bob.session().change_notice(&fx.group);
        assert!(shown.notes.contains(&ChangeNote::QueuedRemovalDropped));
        assert!(fx
            .bob
            .session()
            .acknowledge_change_notice(&fx.group, &shown));
    }))
    .await;
    assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[
            &fx.carol.pubkey_hex(),
            &fx.bob.pubkey_hex(),
            &hex::encode(fx.group.as_slice()),
            &hex::encode(id),
        ],
    );
    assert!(
        fx.bob.session().peek_change_notes(&fx.group).is_empty()
            && removal_targets(&fx.bob).is_empty(),
        "the names a removal's note kept outlived the note",
    );
    assert!(
        seal_finishing(&fx.bob, &fx.group).await.is_ok(),
        "the hold on background sends outlived the note it was raised with",
    );
    drop(plane);
    assert!(
        seal_finishing(&fx.bob, &fx.group).await.is_ok(),
        "a process with no live plane was still held after the note had ended",
    );
}

/// The same hold ends, by itself, when nobody the removal named is in the
/// circle any more: another admin removes the member, this device applies
/// that — still in the burst — and its next background send is sealed. The
/// user is then told nothing more: what they asked for is so, and no removal
/// has to be asked for again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_hold_a_removal_set_aside_raised_ends_when_its_member_is_no_longer_listed() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(true);
    let next = fx
        .alice
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("alice's next commit");
    let id = ngid(&fx.bob, &fx.group).await;
    let _ = plane.processor.process_group_event(&next, &id).await;
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ) && removal_targets(&fx.bob) == [fx.carol.pubkey_hex()],
        "premise: the removal was set aside, and holds the circle's background sends",
    );

    let removal = fx
        .alice
        .circle
        .remove_members_for_test(&fx.group, &[fx.carol.pubkey_hex()])
        .await
        .expect("the other admin removes the member");
    let _ = plane.processor.process_group_event(&removal, &id).await;
    assert!(
        !roster(&fx.bob, &fx.group)
            .await
            .contains(&fx.carol.pubkey_hex()),
        "premise: this device applied the other admin's removal in the burst",
    );

    assert!(
        seal_finishing(&fx.bob, &fx.group).await.is_ok(),
        "a removal set aside went on holding the circle's background sends after the member \
         it named had left the circle",
    );
    assert!(
        removal_targets(&fx.bob).is_empty()
            && fx.bob.session().peek_change_notes(&fx.group).is_empty(),
        "a member no longer in the circle still holds it, or the user is still to be told to \
         ask again for a removal that has been made",
    );
}

/// A removal that named two members holds while either is still listed: the
/// one who has left stops holding, and the other goes on holding the circle's
/// background sends until they are gone too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_that_named_two_holds_until_both_are_gone() {
    let (fx, also) = left_queued_behind_a_closed_pass(4, true).await;
    let dave = &also[0];
    let plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(true);
    let next = fx
        .alice
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("alice's next commit");
    let id = ngid(&fx.bob, &fx.group).await;
    let _ = plane.processor.process_group_event(&next, &id).await;
    let mut named = removal_targets(&fx.bob);
    named.sort();
    let mut both = vec![fx.carol.pubkey_hex(), dave.pubkey_hex()];
    both.sort();
    assert!(
        named == both
            && matches!(
                seal_finishing(&fx.bob, &fx.group).await,
                Err(CircleError::EngineHeld)
            ),
        "premise: the removal of two was set aside, both are kept, and it holds",
    );

    for (leaver, left) in [(&fx.carol, vec![dave.pubkey_hex()]), (dave, Vec::new())] {
        let removal = fx
            .alice
            .circle
            .remove_members_for_test(&fx.group, &[leaver.pubkey_hex()])
            .await
            .expect("the other admin removes one of them");
        let _ = plane.processor.process_group_event(&removal, &id).await;
        assert!(
            !roster(&fx.bob, &fx.group)
                .await
                .contains(&leaver.pubkey_hex()),
            "premise: this device applied the removal in the burst",
        );
        let sealed = seal_finishing(&fx.bob, &fx.group).await;
        if left.is_empty() {
            assert!(
                sealed.is_ok()
                    && removal_targets(&fx.bob).is_empty()
                    && fx.bob.session().peek_change_notes(&fx.group).is_empty(),
                "the hold outlived the last member the removal named",
            );
        } else {
            assert!(
                matches!(sealed, Err(CircleError::EngineHeld))
                    && removal_targets(&fx.bob) == left
                    && fx.bob.session().peek_change_notes(&fx.group)
                        == [ChangeNote::QueuedRemovalDropped],
                "with one of two named members gone the hold ended, or the one who left is \
                 still kept, or the one who stays was forgotten",
            );
        }
    }
}

/// A member this device's own UNAPPLIED removal no longer lists is still in
/// the circle: the engine reports the roster a staged commit would leave,
/// and a commit that every relay then refuses is undone. The hold stands
/// through both, and nobody it named is forgotten.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_staged_and_not_applied_ends_no_hold_and_forgets_nobody() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(true);
    let next = fx
        .alice
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("alice's next commit");
    let id = ngid(&fx.bob, &fx.group).await;
    let _ = plane.processor.process_group_event(&next, &id).await;
    assert!(
        removal_targets(&fx.bob) == [fx.carol.pubkey_hex()],
        "premise: the removal was set aside"
    );

    // The admin asks again from the foreground, and no relay can be reached.
    plane.processor.for_test().set_background_burst(false);
    for relay in [RELAY, OTHER] {
        plane.transport.answer(relay, [Answer::Unreachable]);
    }
    let _ = a_driver(&plane, &DriveMode::Full)
        .remove_members(&fx.bob.circle, &fx.group, &[fx.carol.pubkey_hex()])
        .await;
    plane.processor.for_test().set_background_burst(true);
    assert!(
        staged_ref(&fx.bob, &fx.group).await.is_some()
            && !roster(&fx.bob, &fx.group)
                .await
                .contains(&fx.carol.pubkey_hex()),
        "premise: the removal is staged, and the engine reports the roster it would leave",
    );
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ) && removal_targets(&fx.bob) == [fx.carol.pubkey_hex()],
        "a member a staged, unapplied removal no longer lists was forgotten: the hold would \
         not come back if the removal were undone",
    );

    // Every relay then refuses it: undone, and the member is listed again.
    for relay in [RELAY, OTHER] {
        plane.transport.answer(relay, [Answer::Refused]);
    }
    plane.clock.set(60 * SECOND_MS);
    plane.processor.for_test().set_background_burst(false);
    plane.processor.for_test().drive_due().await;
    plane.processor.for_test().set_background_burst(true);
    assert!(
        staged_ref(&fx.bob, &fx.group).await.is_none()
            && roster(&fx.bob, &fx.group)
                .await
                .contains(&fx.carol.pubkey_hex()),
        "premise: every relay's refusal undid the removal",
    );
    assert!(
        matches!(
            seal_finishing(&fx.bob, &fx.group).await,
            Err(CircleError::EngineHeld)
        ) && removal_targets(&fx.bob) == [fx.carol.pubkey_hex()]
            && fx
                .bob
                .session()
                .peek_change_notes(&fx.group)
                .contains(&ChangeNote::QueuedRemovalDropped),
        "after its second attempt was undone the removal no longer holds the circle's \
         background sends, with the member it named back in the circle",
    );
}

/// The driver over `plane`'s transport, publisher and clock, in `mode`.
fn a_driver<'a>(plane: &'a Plane, mode: &'a dyn ModeSource) -> Publishing<'a, ScriptedFanout> {
    Publishing {
        fanout: &*plane.transport,
        publisher: &*plane.unrecorded,
        clock: &*plane.clock,
        deadline_ms: None,
        mode,
    }
}

/// The member ids `member`'s circle store keeps for removals set aside
/// unmade that no applied commit has taken out — the ones that hold — as
/// hex.
fn removal_targets(member: &CircleMember) -> Vec<String> {
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    let store = rusqlite::Connection::open(
        member
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens");
    let mut statement = store
        .prepare("SELECT member FROM removal_targets WHERE gone_epoch IS NULL")
        .expect("the table exists");
    let targets = statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0).map(hex::encode))
        .expect("the targets are read")
        .collect::<Result<Vec<_>, _>>()
        .expect("each target is read");
    targets
}

/// The same when a peer's location is waiting behind that commit as well.
/// The engine then answers "a deadline is due now" for the circle while its
/// reservation still holds it — which read as "a pass is about to open" kept
/// the queued change, and the circle behind it, for good. The reservation is
/// read from the engine's stored pass instead: the change is retired, and
/// the commit and the location behind it are both applied in the burst.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_waiting_behind_a_held_commit_does_not_hide_the_reservation_from_a_burst() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let next = fx
        .alice
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("alice's next commit");
    let behind = sealed_by(&fx.alice, &fx.group, 7.125).await;
    // Taken in with no advance: the commit is held behind the reservation,
    // and the location sealed at the epoch it leads to waits behind both.
    for event in [&next, &behind] {
        fx.bob
            .session()
            .process_event(event)
            .await
            .expect("the event is ingested");
    }
    assert_eq!(
        (
            fx.bob.session().receive_retick_after(&fx.group).await,
            queue_len(&fx.bob, &fx.group).await,
        ),
        (Some(Duration::ZERO), 1),
        "premise: the engine announces a deadline as due now for a circle its reservation \
         still holds",
    );

    let mut plane = Plane::over(&fx.bob.circle);
    plane.processor.for_test().set_background_burst(true);
    let id = ngid(&fx.bob, &fx.group).await;
    let later = sealed_by(&fx.alice, &fx.group, 8.125).await;
    let _ = plane.processor.process_group_event(&later, &id).await;

    assert_eq!(
        (
            fx.bob.circle.group_epoch(&fx.group).await.expect("epoch"),
            queue_len(&fx.bob, &fx.group).await,
        ),
        (
            fx.alice.circle.group_epoch(&fx.group).await.expect("epoch"),
            0,
        ),
        "a location waiting behind a held commit hid the reservation: the circle stayed at \
         its epoch behind a change a burst cannot make",
    );
    let carried = plane.locations();
    assert!(
        carried.iter().any(|(_, content)| content.contains("7.125"))
            && carried.iter().any(|(_, content)| content.contains("8.125")),
        "what waited behind the reservation was not delivered once it was retired",
    );
    assert!(
        records_of(&fx.bob, &fx.group).await.is_empty()
            && staged_ref(&fx.bob, &fx.group).await.is_none()
            && plane.transport.call_count() == 0,
    );
}

// ── The re-staging wait ──────────────────────────────────────────────────────

/// The wait a refused eviction earned holds on every hold of the claimed
/// plane that can stage it again. After the driver rolled the eviction back,
/// the engine arms it again; inside the wait neither the plane's receive —
/// which advances in full under its staging hold — nor the drive that receive
/// asks for stages it: nothing staged, nothing recorded, no relay called.
/// When the wait is over the next drive makes it.
///
/// The price, said where it is paid: while the wait runs this device shares
/// nothing to that circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_every_relay_refused_is_not_staged_again_inside_its_wait() {
    let (fx, plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    let admin = fx.admin();
    let leaver = fx.members[1].pubkey_hex();
    plane.transport.answer(RELAY, [Answer::Refused]);
    plane.processor.for_test().drive_due().await;
    assert_eq!(
        plane.transport.calls().len(),
        1,
        "premise: sent once and refused"
    );
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && roster(admin, &fx.group).await.contains(&leaver),
        "premise: every relay's refusal undid the eviction",
    );

    // The engine arms the rolled-back eviction again a few tens of
    // milliseconds out, on its own clock: waited out, so the receive meets it.
    if let Some(due) = admin.session().eviction_due_after_for_test(&fx.group).await {
        tokio::time::sleep(due + Duration::from_millis(5)).await;
    }
    let id = ngid(admin, &fx.group).await;
    plane.clock.set(30 * SECOND_MS);
    for latitude in [7.5, 8.5] {
        let location = sealed_by(&fx.members[2], &fx.group, latitude).await;
        assert_eq!(
            plane.processor.process_group_event(&location, &id).await,
            GroupProcessOutcome::Applied,
            "premise: the claimed plane took the receive in",
        );
    }
    admin.session().mark_caught_up_for_test(&fx.group);
    plane.clock.set(59 * SECOND_MS);
    plane.processor.for_test().drive_due().await;
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && records_of(admin, &fx.group).await.is_empty()
            && plane.transport.call_count() == 0,
        "a receive or a drive inside the wait staged, recorded or sent the eviction",
    );

    // The wait is over.
    plane.clock.set(60 * SECOND_MS);
    plane.transport.answer(RELAY, [Answer::Accepted]);
    plane.processor.for_test().drive_due().await;
    assert!(
        plane.transport.calls().len() == 1 && !roster(admin, &fx.group).await.contains(&leaver),
        "the eviction was held past its wait",
    );
}

// ── A commit a hold could neither record nor roll back ───────────────────────

fn db_of(member: &CircleMember) -> (std::path::PathBuf, storage_sqlite::SqlCipherKey) {
    (
        StorageConfig::new(member.dir.path()).database_path(),
        StorageConfig::test_sqlcipher_key().expect("test key"),
    )
}

/// An eviction the live plane staged whose record could not be written and
/// whose rollback failed too is staged, unsent, and owed to NOBODY: nothing
/// sends a commit without a record, so a drive has nothing to publish. Its
/// circle is told, and the next hold that stages rolls it back — nothing ever
/// left the device.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_neither_recorded_nor_undone_is_owed_to_nobody_and_undone_at_the_next_hold() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    let (db, key) = db_of(admin);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    // Refused more times than one ingest can ask: an ingest serves the
    // engine's deadlines in place, and each of those holds tries the rollback
    // again, so a single refusal could be spent and the commit undone before
    // this test looks.
    for _ in 0..MAX_CONVERGENCE_RETICKS + 2 {
        admin.session().fail_next_rollback_for_test(false);
    }
    let armed = admin.session().rollback_faults_left_for_test();
    let id = ngid(admin, &fx.group).await;
    let leave = fx.members[1]
        .circle
        .propose_leave(&fx.group)
        .await
        .expect("the member proposes its leave")
        .expect("a first leave in this epoch proposes");
    plane.processor.process_group_event(&leave, &id).await;
    feed_leave_ticks(&plane, &fx, 2, || async {
        admin.session().rollback_faults_left_for_test() < armed
    })
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");

    assert!(
        staged_ref(admin, &fx.group).await.is_some()
            && records_of(admin, &fx.group).await.is_empty()
            && admin.session().rollback_faults_left_for_test() > 0,
        "premise: staged, with no record, and its rollback still refused",
    );
    assert_eq!(
        admin.session().peek_change_notes(&fx.group),
        [ChangeNote::ChangeUnrecorded]
    );
    plane.processor.for_test().drive_due().await;
    assert!(
        plane.transport.call_count() == 0,
        "a commit with no record was published",
    );

    // The first hold whose rollback is not refused undoes it. Nothing ever
    // left the device, and the engine has the eviction armed again.
    feed_leave_ticks(&plane, &fx, 2, || async {
        staged_ref(admin, &fx.group).await.is_none()
    })
    .await;
    assert!(
        records_of(admin, &fx.group).await.is_empty() && plane.transport.call_count() == 0,
        "undoing a commit that was never recorded sent or owed something",
    );
    // A receive pass does not stage again, inside itself, what it has just
    // rolled back: the circle's next advance does, and with the store taking
    // writes the eviction is recorded.
    let due = admin
        .session()
        .eviction_due_after_for_test(&fx.group)
        .await
        .expect("the engine armed the eviction again");
    tokio::time::sleep(due + Duration::from_millis(5)).await;
    let staged = admin
        .session()
        .advance_for_drive(&fx.group, plane.clock.now_ms())
        .await
        .expect("the circle's next advance");
    assert_eq!(
        staged.fanouts.len(),
        1,
        "the eviction, staged again, has no record"
    );
    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the eviction, staged again, has exactly one record"));
    assert_eq!(record.mls, FanoutMls::Pending);
}

/// A rollback that errors AFTER its rewind landed is read from the state,
/// not from the call: the commit is gone, so nothing is kept as "still
/// staged", no dead ref is remembered, and its circle is not told a change
/// could not be recorded. What the failed call had emitted is taken in.
#[tokio::test]
async fn a_rollback_that_errors_after_its_rewind_landed_is_read_as_rolled_back() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    let (db, key) = db_of(admin);
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    admin.session().fail_next_rollback_for_test(true);
    let said = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let lines = Box::pin(capture_haven_log_here(async {
        let id = ngid(admin, &fx.group).await;
        let proposal = fx.members[1]
            .circle
            .propose_leave(&fx.group)
            .await
            .expect("the member proposes its leave")
            .expect("a first leave in this epoch proposes");
        plane.processor.process_group_event(&proposal, &id).await;
        feed_leave_ticks(&plane, &fx, 2, || async {
            admin.session().rollback_faults_left_for_test() == 0
        })
        .await;
        said.store(true, Ordering::SeqCst);
    }))
    .await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    assert!(said.load(Ordering::SeqCst));

    let line: Vec<_> = lines
        .iter()
        .filter(|line| {
            line.message
                .contains("a rollback that failed after it had rewound its commit is read as done")
        })
        .cloned()
        .collect();
    assert_eq!(line.len(), 1, "the rewind that errored was not said once");
    assert_no_needles(
        &line,
        &[
            &hex::encode(fx.group.as_slice()),
            &admin.pubkey_hex(),
            &fx.members[1].pubkey_hex(),
            "live-canary7d2f",
        ],
    );
    assert!(
        !admin
            .session()
            .peek_change_notes(&fx.group)
            .contains(&ChangeNote::ChangeUnrecorded),
        "a commit that was rolled back was said to be staged with no record",
    );
    assert!(records_of(admin, &fx.group).await.is_empty());
}

// ── A proposal no record could be written for ────────────────────────────────

/// The engine proposes this device's leave again when its circle's epoch
/// moves. In the foreground that proposal is recorded like any other; when
/// its record cannot be written it must still leave the device, once. It is
/// kept for the drive, which publishes it through the drive pool's
/// publisher: never from the ingest worker, never on the engine's client,
/// and never in a lifecycle that does not drive. A further
/// drive sends nothing more.
///
/// It is kept for the foreground it was minted in and no longer: when that
/// foreground ends first — here a background burst opens — it is let go, and
/// no later foreground publishes it, by then a leave for an epoch that may be
/// long past. What the departing member loses is that epoch's proposal: the
/// engine proposes the leave again when the circle's epoch next moves.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leave_proposed_again_with_no_record_is_published_once_and_only_by_a_foreground_drive() {
    for foreground_ends_first in [false, true] {
        a_kept_proposal_is_published_by_its_own_foreground_only(foreground_ends_first).await;
    }
}

async fn a_kept_proposal_is_published_by_its_own_foreground_only(foreground_ends_first: bool) {
    let fx = setup_circle(3, &[RELAY]).await;
    let (admin, leaver) = (fx.admin(), &fx.members[1]);
    let _superseded = leaver
        .circle
        .propose_leave(&fx.group)
        .await
        .expect("the member proposes its leave")
        .expect("a first leave in this epoch proposes");
    // The admin commits without having seen that proposal, which supersedes
    // it: the leaver's engine proposes the leave again for the new epoch.
    let moved = admin
        .circle
        .update_relays_for_test(&fx.group, &[RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("the admin stages a relay change");

    let plane = Plane::over(&leaver.circle);
    plane.processor.for_test().set_background_burst(false);
    let (db, key) = db_of(leaver);
    let id = ngid(leaver, &fx.group).await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    plane.processor.process_group_event(&moved, &id).await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    assert!(
        records_of(leaver, &fx.group).await.is_empty(),
        "premise: the leave proposed again has no record",
    );
    assert!(
        plane.unrecorded.handed().is_empty(),
        "the ingest worker published a proposal itself",
    );

    if foreground_ends_first {
        plane.processor.for_test().set_background_burst(true);
        plane.processor.for_test().drive_due().await;
        assert!(
            plane.unrecorded.handed().is_empty(),
            "a background burst published what the foreground kept for its drive",
        );
        plane.processor.for_test().set_background_burst(false);
        plane.processor.for_test().drive_due().await;
        assert!(
            plane.unrecorded.handed().is_empty() && plane.transport.call_count() == 0,
            "a proposal kept for a foreground that ended was published by a later one",
        );
        return;
    }

    plane.processor.for_test().drive_due().await;
    let [proposal] = <[Event; 1]>::try_from(plane.unrecorded.handed()).unwrap_or_else(|sent| {
        panic!(
            "the leave must be published exactly once, got {}",
            sent.len()
        )
    });
    assert!(
        plane.transport.call_count() == 0,
        "a proposal with no record went through the fanout transport",
    );
    // It is the leave itself: the admin's engine makes the eviction from it.
    let (_, evicted) = admin
        .circle
        .ingest_landing_for_test(&proposal)
        .await
        .expect("the admin ingests it");
    assert_eq!(evicted.len(), 1);

    plane.processor.for_test().drive_due().await;
    assert_eq!(
        plane.unrecorded.handed().len(),
        1,
        "a proposal already published once was published again",
    );
}

// ── The engine's own refusal ─────────────────────────────────────────────────

/// An event arrives on the live plane while the engine is held: a commit an
/// earlier rollback rewound cannot be retired, and no engine call is made
/// until it is. Nothing about the event was decided, so it is not reported
/// as one the engine could not take, nothing is published or failed for it,
/// and what is logged names nothing: it is held, and the same event is
/// applied once the engine is handed over again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_arriving_while_the_engine_is_held_is_held_and_applied_once_it_is_not() {
    use haven_core::nostr::mls::storage::set_commit_retirement_fault_for_test;

    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let mut plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    let staged = admin
        .session()
        .update_relays(&fx.group, vec![RELAY.to_string(), OTHER.to_string()])
        .await
        .expect("a relay change is staged, and no row written");
    let commit = staged
        .publish
        .iter()
        .find_map(|work| match work {
            haven_core::nostr::mls::types::PublishWork::GroupEvolution { msg, .. } => {
                nostr::EventId::from_slice(msg.id.as_slice()).ok()
            }
            _ => None,
        })
        .expect("the call staged a commit");
    let pending = staged_ref(admin, &fx.group).await.expect("staged");
    let (db, key) = db_of(admin);
    set_commit_retirement_fault_for_test(&db, &key, commit.as_bytes(), true).expect("arm");
    let _ = admin.circle.session().publish_failed(pending).await;

    let id = ngid(admin, &fx.group).await;
    let inbound = sealed_by(&fx.members[2], &fx.group, 7.5).await;
    let lines = capture_haven_log(Box::pin(async {
        assert_eq!(
            plane.processor.process_group_event(&inbound, &id).await,
            GroupProcessOutcome::Held,
        );
        plane.processor.for_test().drive_due().await;
    }))
    .await;
    let mut reported = Vec::new();
    while let Ok(event) = plane.bus.try_recv() {
        reported.push(event);
    }
    assert!(
        reported.is_empty(),
        "an event the engine was never asked about was reported on the bus",
    );
    assert!(
        plane.unrecorded.handed().is_empty() && plane.transport.call_count() == 0,
        "something was sent while the engine was held",
    );
    assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[
            &hex::encode(fx.group.as_slice()),
            &hex::encode(id),
            &inbound.id.to_hex(),
            &commit.to_hex(),
            &fx.members[2].pubkey_hex(),
        ],
    );

    set_commit_retirement_fault_for_test(&db, &key, commit.as_bytes(), false).expect("disarm");
    assert_eq!(
        plane.processor.process_group_event(&inbound, &id).await,
        GroupProcessOutcome::Applied,
        "the held event was not applied once the engine could be called",
    );
    assert_eq!(
        plane.locations().len(),
        1,
        "the held location did not reach the bus once it was applied",
    );
}

// ── Every path that can meet a circle holding a pending record ──────────────
//
// After this change a circle can hold a driver's record while every other
// path of the app is still the legacy one. Each of those paths is run here
// against a circle whose eviction is recorded, sent once and unanswered — a
// commit a relay may hold — and must leave it exactly as it found it: not
// rolled back, not confirmed, not sent again, not staged again.

/// A three-member circle on an in-process relay whose admin's live plane has
/// recorded an eviction and sent it once to a relay that did not answer.
struct Awaiting {
    fx: CircleFixture,
    plane: Plane,
    relay: MockRelay,
    url: String,
    pending: PendingStateRef,
    standing: Vec<Standing>,
}

async fn an_eviction_awaiting_its_relay() -> Awaiting {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = setup_circle(3, &[&url]).await;
    let plane = Plane::over(&fx.admin().circle);
    plane.processor.for_test().set_background_burst(false);
    feed_leave(&plane, &fx, 1, 2).await;
    plane.transport.answer(&url, [Answer::Silent]);
    plane.processor.for_test().drive_due().await;
    assert_eq!(plane.transport.calls().len(), 1, "premise: sent once");
    let pending = staged_ref(fx.admin(), &fx.group)
        .await
        .expect("premise: still staged");
    let standing = standing_of(fx.admin(), &fx.group).await;
    assert_eq!(standing.len(), 1, "premise: one record");
    Awaiting {
        fx,
        plane,
        relay,
        url,
        pending,
        standing,
    }
}

impl Awaiting {
    /// The record and its commit are as they were, and nothing was sent for
    /// it by anybody.
    async fn assert_untouched_by(&self, path: &str) {
        let admin = self.fx.admin();
        assert_eq!(
            standing_of(admin, &self.fx.group).await,
            self.standing,
            "{path}: the record was changed — sent again, confirmed, rolled back or replaced",
        );
        assert_eq!(
            staged_ref(admin, &self.fx.group).await,
            Some(self.pending),
            "{path}: the recorded commit is no longer the one staged",
        );
        assert!(
            self.plane.unrecorded.handed().is_empty() && self.plane.transport.call_count() == 0,
            "{path}: something was sent for a recorded commit",
        );
        assert!(
            roster(admin, &self.fx.group).await.len() == 2,
            "{path}: the staged roster moved",
        );
    }
}

/// The sweep every wake runs — in either lifecycle; nothing in it can tell
/// which — over a circle awaiting its relay: it fetches, the engine holds
/// what it fetched behind the pending commit, and the sweep publishes
/// nothing, resolves nothing and drives nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_legacy_sweep_leaves_a_recorded_commit_as_it_found_it() {
    let fx = an_eviction_awaiting_its_relay().await;
    let relay_mgr = RelayManager::new();
    let waiting = sealed_by(&fx.fx.members[2], &fx.fx.group, 9.5).await;
    relay_mgr
        .publish_event(&waiting, std::slice::from_ref(&fx.url))
        .await
        .expect("a peer's location is on the relay");

    let out = run_catchup_all_circles(&fx.fx.admin().circle, &relay_mgr, 20).await;

    assert_eq!(out.circles_swept, 1, "premise: the circle was swept");
    fx.assert_untouched_by("the legacy sweep").await;
    let on_relay = relay_mgr
        .fetch_events(
            nostr::Filter::new().kind(Kind::Custom(445)),
            std::slice::from_ref(&fx.url),
            None,
        )
        .await
        .expect("read the relay back");
    assert!(
        on_relay.iter().all(|event| event.id == waiting.id),
        "the sweep published something of this device's to the relay",
    );
    drop(fx.relay);
}

/// A background burst of the live plane over a circle awaiting its relay.
/// What the burst ingests is held unread behind the pending commit, and
/// nothing is staged again; a drive asked for in the burst before the relay
/// is due makes no call, and one asked for when it is due sends that relay
/// the same bytes once and — unanswered again — resolves nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_leaves_a_recorded_commit_as_it_found_it() {
    let fx = an_eviction_awaiting_its_relay().await;
    let admin = fx.fx.admin();
    let id = ngid(admin, &fx.fx.group).await;

    fx.plane.processor.for_test().set_background_burst(true);
    let waiting = sealed_by(&fx.fx.members[2], &fx.fx.group, 9.5).await;
    assert_eq!(
        fx.plane.processor.process_group_event(&waiting, &id).await,
        GroupProcessOutcome::Buffered,
    );
    fx.plane.processor.for_test().drive_due().await;
    fx.assert_untouched_by("a background burst before the relay is due")
        .await;

    fx.plane.clock.set(3_600 * SECOND_MS);
    fx.plane.processor.for_test().drive_due().await;
    let again = fx.plane.transport.calls();
    let sent = records_of(admin, &fx.fx.group).await.remove(0);
    assert!(
        again.len() == 1 && again[0].event_id == sent.event_id && again[0].payload == sent.payload,
        "a burst did not send the relay that was due the same bytes once",
    );
    assert!(
        sent.mls == FanoutMls::Pending
            && sent.attempts == [2]
            && staged_ref(admin, &fx.fx.group).await == Some(fx.pending)
            && admin.session().peek_change_notes(&fx.fx.group).is_empty()
            && fx.plane.unrecorded.handed().is_empty()
            && roster(admin, &fx.fx.group).await.len() == 2,
        "a burst resolved or replaced a commit no relay has acknowledged",
    );
}

/// What a location send does for a circle awaiting its relay — the question a
/// background publish tick asks every couple of minutes while the app is not
/// `resumed`. Each attempt is answered with the typed deferral, awaiting
/// relays. Nothing is sealed or queued, so nothing stale is banked; the
/// record is untouched; no relay is called; and what is logged names nothing.
/// The circle does not share until a drive resolves its record.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_send_for_a_circle_awaiting_its_relay_is_deferred_typed_and_touches_nothing() {
    let fx = an_eviction_awaiting_its_relay().await;
    let admin = fx.fx.admin();
    let group = &fx.fx.group;
    fx.plane.processor.for_test().set_background_burst(true);

    let driver: Publishing<'_, dyn FanoutSend> = Publishing {
        fanout: fx.plane.transport.as_ref(),
        publisher: fx.plane.unrecorded.as_ref(),
        clock: fx.plane.clock.as_ref(),
        deadline_ms: None,
        mode: &DriveMode::FinishOnly,
    };
    let lines = Box::pin(capture_haven_log(async {
        for _ in 0..3 {
            let sent = driver
                .seal_location(&admin.circle, group, &LocationMessage::new(1.0, 2.0))
                .await
                .expect("the send is answered");
            assert!(
                matches!(sent.seal, LocationSeal::Deferred(SendHeld::AwaitingRelays)),
                "a send for a circle awaiting its relay was not the typed deferral",
            );
        }
    }))
    .await;
    fx.assert_untouched_by("a location send").await;
    assert_eq!(
        admin
            .session()
            .queued_intent_count_for_test(group)
            .await
            .expect("the queue"),
        0,
        "the deferred fix was left queued, to be sealed stale later",
    );
    let id = ngid(admin, group).await;
    assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[
            &hex::encode(group.as_slice()),
            &hex::encode(id),
            &admin.pubkey_hex(),
            &fx.fx.members[1].pubkey_hex(),
            &fx.url,
        ],
    );
}

// ── The foreground ends without notice ───────────────────────────────────────

/// The foreground ends while a drive's call is on its way. The call is not
/// cut and nothing is rolled back because of the transition: the pause that
/// follows waits for the pass on the same count it waits on for any publish,
/// and the pass takes no further relay — a second record that was due is not
/// begun, and nothing is stored for it. The answer that was on its way is
/// recorded as what it was.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_under_way_when_the_foreground_ends_is_waited_for_and_begins_no_further_call() {
    let (fx, plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    let admin = fx.admin();
    // A second circle of the admin's, with a commit of its own that is due.
    let relays = vec![OTHER.to_string()];
    let solo = admin
        .circle
        .create_circle(
            &admin.keys,
            Vec::new(),
            &haven_core::circle::CircleConfig::new("Solo").with_relays(relays.clone()),
        )
        .await
        .expect("a second circle")
        .circle
        .mls_group_id;
    let second = admin
        .session()
        .update_relays_staging(
            &solo,
            vec![OTHER.to_string(), RELAY.to_string()],
            plane.clock.now_ms(),
        )
        .await
        .expect("a relay change is staged")
        .fanouts;
    assert_eq!(second.len(), 1, "premise: a second record");
    let evicting = staged_ref(admin, &fx.group).await.expect("staged");

    plane.transport.park();
    let pass = plane.processor.for_test().drive_due();
    tokio::pin!(pass);
    tokio::select! {
        biased;
        () = &mut pass => panic!("the drive finished while its call was parked"),
        () = plane.transport.parked() => {}
    }
    assert_eq!(plane.processor.in_flight_publishes(), 1);

    // The app goes to the background: a pause begins.
    plane.processor.for_test().leave_foreground();
    let drained = plane.processor.wait_publishes_drained();
    tokio::pin!(drained);
    assert!(
        futures::poll!(&mut drained).is_pending(),
        "a pause did not wait for the drive under way",
    );

    // The relay never answers this call; the pass ends at its own pace.
    plane.transport.unpark();
    tokio::join!(&mut pass, &mut drained);

    let calls = plane.transport.calls();
    assert_eq!(
        calls.len(),
        1,
        "a pass that outlived the foreground began another call",
    );
    assert_eq!(
        staged_ref(admin, &fx.group).await,
        Some(evicting),
        "the commit whose call was under way was rolled back or applied with no answer",
    );
    let untouched = admin
        .session()
        .fanout_probe_for_test(&second[0])
        .await
        .expect("the store is read")
        .expect("the second record is still there");
    assert!(
        untouched.attempts.iter().all(|attempts| *attempts == 0)
            && untouched
                .statuses
                .iter()
                .all(|status| *status == FanoutTargetStatus::NotAttempted),
        "a record that was not begun before the foreground ended has an attempt stored",
    );
}

/// A session stopped while a drive's call is on its way: the call is given
/// up at once rather than waited out, and recorded as what it is — an attempt
/// that never returned, possibly exposed. Nothing is rolled back, and the
/// next process sends the same bytes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_under_way_at_a_stop_gives_its_relay_up_and_keeps_the_attempt_as_possibly_exposed()
{
    let fx = setup_circle(3, &[RELAY]).await;
    let (halt, halted) = tokio::sync::watch::channel(false);
    let mut plane = Plane::over(&fx.admin().circle);
    plane.processor.set_halt_signal(halted);
    plane.processor.for_test().set_background_burst(false);
    feed_leave(&plane, &fx, 1, 2).await;
    let admin = fx.admin();
    let evicting = staged_ref(admin, &fx.group).await.expect("staged");

    plane.transport.park();
    {
        let pass = plane.processor.for_test().drive_due();
        tokio::pin!(pass);
        tokio::select! {
            biased;
            () = &mut pass => panic!("the drive finished while its call was parked"),
            () = plane.transport.parked() => {}
        }
        // The stop: the foreground ends and the session's cancel is raised.
        plane.processor.for_test().leave_foreground();
        halt.send_replace(true);
        pass.await;
    }

    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the record is still there"));
    assert_eq!(
        (record.statuses.as_slice(), record.attempts.as_slice()),
        (&[FanoutTargetStatus::PossiblyExposed][..], &[1][..]),
        "a call given up at a stop was not kept as possibly exposed",
    );
    assert_eq!(staged_ref(admin, &fx.group).await, Some(evicting));
    assert_eq!(plane.transport.calls().len(), 1);
}

// ── Kills, at each durable write of the live plane ───────────────────────────

/// A kill after the record was written and before any call: the next process
/// finds the commit restored under its record. A session that has only been
/// started leaves it alone; the first foreground drive sends the same bytes,
/// and the relay's acknowledgement applies it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_after_staging_an_owed_removal_publishes_it_from_the_next_foreground_drive() {
    let (fx, plane, leave) = an_eviction_recorded_with_its_leave(&[RELAY]).await;
    let before = standing_of(fx.admin(), &fx.group).await;
    assert_eq!(plane.transport.call_count(), 0, "premise: never sent");
    drop(plane);
    let group = fx.group.clone();
    let mut members = fx.members;
    let departed = members.remove(1);
    let leaver = departed.pubkey_hex();
    let admin = members.remove(0).reopen();
    let witness = members.remove(0);

    assert_eq!(standing_of(&admin, &group).await, before);
    assert!(staged_ref(&admin, &group).await.is_some());
    let plane = Plane::over(&admin.circle);
    plane.transport.answer(RELAY, [Answer::Accepted]);
    plane.processor.for_test().drive_due().await;
    assert_eq!(
        plane.transport.call_count(),
        0,
        "a session that was only started drove a stored record",
    );

    plane.processor.for_test().set_background_burst(false);
    plane.processor.for_test().drive_due().await;
    let calls = plane.transport.calls();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].event_id == before[0].0 && calls[0].payload == before[0].1);
    assert!(!roster(&admin, &group).await.contains(&leaver));
    let eviction = Event::from_json(&calls[0].payload).expect("a signed event");
    assert_the_eviction_removed(&admin, &witness, &departed, &group, &leave, &eviction).await;
}

/// A kill while the call was on its way, the attempt stored as begun: the
/// next foreground drive records it as possibly exposed BEFORE it sends
/// again, sends the same bytes on the relay's schedule, and the commit is
/// applied on the acknowledgement. Nothing rolls it back in between.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kill_during_the_first_call_is_recorded_possibly_exposed_and_sent_again_on_schedule() {
    let (fx, plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    let sent = standing_of(fx.admin(), &fx.group).await;
    plane.transport.park();
    {
        let pass = plane.processor.for_test().drive_due();
        tokio::pin!(pass);
        tokio::select! {
            biased;
            () = &mut pass => panic!("the drive finished while its call was parked"),
            () = plane.transport.parked() => {}
        }
        // The process dies here: the pass is dropped where it stands.
    }
    drop(plane);
    let group = fx.group.clone();
    let mut members = fx.members;
    let leaver = members.remove(1).pubkey_hex();
    let admin = members.remove(0).reopen();
    let [found] = <[FanoutProbe; 1]>::try_from(records_of(&admin, &group).await)
        .unwrap_or_else(|_| panic!("the record survived"));
    assert_eq!(found.statuses, [FanoutTargetStatus::Attempting]);

    let plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    plane.transport.answer(RELAY, [Answer::Refused]);
    // Inside the relay's wait: recorded as possibly exposed, not sent.
    plane.clock.set(SECOND_MS);
    plane.processor.for_test().drive_due().await;
    assert_eq!(plane.transport.call_count(), 0);
    let [recorded] = <[FanoutProbe; 1]>::try_from(records_of(&admin, &group).await)
        .unwrap_or_else(|_| panic!("the record is still there"));
    assert_eq!(recorded.statuses, [FanoutTargetStatus::PossiblyExposed]);

    // When the wait is over the same bytes go again; this relay now refuses
    // every attempt, and a commit a relay may hold is still not rolled back.
    plane.clock.set(31 * SECOND_MS);
    plane.processor.for_test().drive_due().await;
    let calls = plane.transport.calls();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].event_id == sent[0].0 && calls[0].payload == sent[0].1);
    assert!(
        staged_ref(&admin, &group).await.is_some()
            && roster(&admin, &group).await.len() == 2
            && !roster(&admin, &group).await.contains(&leaver),
        "a commit a relay may hold was rolled back on a later refusal",
    );
    assert!(admin.session().peek_change_notes(&group).is_empty());
}

/// A kill between the engine's staging of an eviction and its record — the
/// record's write failed, the rollback failed, and the process died with the
/// commit staged. The next open gives an eviction no record, the circle
/// reads stable, and the live plane in the foreground heals it the one way
/// it can be healed: the other remaining member's eviction for the same
/// departure, ingested like any event, is applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_eviction_killed_between_its_staging_and_its_record_is_healed_through_the_live_plane() {
    let fx = setup_circle(3, &[RELAY]).await;
    let plane = Plane::over(&fx.admin().circle);
    plane.processor.for_test().set_background_burst(false);
    let (db, key) = db_of(fx.admin());
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, true).expect("arm");
    fx.admin().session().fail_next_rollback_for_test(false);
    let leave = feed_leave(&plane, &fx, 1, 2).await;
    set_engine_write_fault_for_test(&db, &key, EngineWrite::FanoutPut, false).expect("disarm");
    assert!(
        staged_ref(fx.admin(), &fx.group).await.is_some()
            && records_of(fx.admin(), &fx.group).await.is_empty(),
        "premise: staged with no record",
    );
    drop(plane);
    let group = fx.group.clone();
    let mut members = fx.members;
    let stayer = members.remove(2);
    let leaver = members.remove(1);
    let admin = members.remove(0).reopen();
    assert!(
        records_of(&admin, &group).await.is_empty() && staged_ref(&admin, &group).await.is_none(),
        "the open gave a record to an eviction, or restored it as pending with none",
    );

    // The other remaining member commits the departure.
    stayer
        .session()
        .process_event(&leave)
        .await
        .expect("the leave is ingested");
    let mut theirs = None;
    for _ in 0..8 {
        if let Some(wait) = stayer.session().receive_retick_after(&group).await {
            tokio::time::sleep(wait).await;
        }
        let effects = stayer
            .session()
            .stage_unrecorded_for_test(&group)
            .await
            .expect("advance");
        if let Some((msg, pending)) = effects.publish.iter().find_map(|work| match work {
            haven_core::nostr::mls::types::PublishWork::AutoPublish { msg, pending } => {
                Some((msg.clone(), *pending))
            }
            _ => None,
        }) {
            stayer
                .circle
                .session()
                .confirm_published(pending)
                .await
                .expect("the eviction is applied");
            theirs = Some(
                haven_core::nostr::mls::SessionManager::transport_message_to_event(&msg)
                    .expect("the commit"),
            );
            break;
        }
    }
    let theirs = theirs.expect("the peer staged its eviction");

    let plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    let id = ngid(&admin, &group).await;
    plane.processor.process_group_event(&theirs, &id).await;
    for _ in 0..8 {
        if staged_ref(&admin, &group).await.is_none()
            && !roster(&admin, &group).await.contains(&leaver.pubkey_hex())
            && admin
                .circle
                .seal_location_for_test(&group, &LocationMessage::new(1.0, 2.0))
                .await
                .is_ok()
        {
            assert_eq!(plane.transport.call_count(), 0);
            return;
        }
        // The engine's own deadline for what it holds, never this test's.
        if let Some(wait) = admin.session().receive_retick_after(&group).await {
            tokio::time::sleep(wait + Duration::from_millis(5)).await;
        }
        let tick = sealed_by(&stayer, &group, 3.25).await;
        plane.processor.process_group_event(&tick, &id).await;
    }
    panic!("the peer's eviction did not heal the circle through the live plane");
}

/// A kill between the record's write and the retirement of the queue's copy,
/// for a change the user queued and the live plane released: the next drive
/// sends the recorded commit — the foreground's, or a background burst's,
/// which only finishes — its confirm retires the queue's copy from what is
/// stored, and the change is not released a second time.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_released_change_killed_before_its_queued_copy_is_retired_is_made_once() {
    for burst in [false, true] {
        let fx = a_removal_left_queued_behind_a_closed_pass().await;
        let plane = Plane::over(&fx.bob.circle);
        plane.processor.for_test().set_background_burst(false);
        let (db, key) = db_of(&fx.bob);
        set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, true)
            .expect("arm");
        // Released and recorded; the queue's copy could not be retired.
        plane.transport.answer(RELAY, [Answer::Silent]);
        plane.processor.for_test().drive_due().await;
        set_engine_write_fault_for_test(&db, &key, EngineWrite::QueuedIntentDelete, false)
            .expect("disarm");
        assert_eq!(
            (
                records_of(&fx.bob, &fx.group).await.len(),
                queue_len(&fx.bob, &fx.group).await,
                plane.transport.calls().len(),
            ),
            (1, 1, 1),
            "premise: recorded and sent, with the queue's copy left behind",
        );
        drop(plane);
        let Reserved {
            bob, carol, group, ..
        } = fx;
        let bob = bob.reopen();

        let plane = Plane::over(&bob.circle);
        plane.processor.for_test().set_background_burst(burst);
        plane.transport.answer(RELAY, [Answer::Accepted]);
        plane.clock.set(31 * SECOND_MS);
        plane.processor.for_test().drive_due().await;
        assert_eq!(plane.transport.calls().len(), 1);
        assert!(!roster(&bob, &group).await.contains(&carol.pubkey_hex()));
        // Further drives and advances make nothing more of it.
        for _ in 0..2 {
            plane.clock.set(3_600 * SECOND_MS);
            plane.processor.for_test().drive_due().await;
        }
        assert_eq!(
            (
                queue_len(&bob, &group).await,
                plane.transport.call_count(),
                staged_ref(&bob, &group).await,
            ),
            (0, 0, None),
            "a change that was recorded, killed and confirmed was released a second time",
        );
        assert!(
            !bob.session()
                .peek_change_notes(&group)
                .iter()
                .any(|note| matches!(
                    note,
                    ChangeNote::QueuedChangeDropped | ChangeNote::QueuedRemovalDropped
                )),
            "a change that was made was told to its circle as dropped unmade",
        );
    }
}

// ── Relay respect ────────────────────────────────────────────────────────────

/// A transport that counts every relay it is asked to take and every call.
struct Counting {
    inner: Arc<ScriptedFanout>,
    takes: AtomicU64,
}

#[async_trait::async_trait]
impl FanoutSend for Counting {
    async fn take(&self, target: &str) -> Option<haven_core::relay::fanout::Taken> {
        self.takes.fetch_add(1, Ordering::SeqCst);
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &haven_core::nostr::mls::types::TransportMessage,
        taken: haven_core::relay::fanout::Taken,
    ) -> haven_core::relay::fanout::FanoutTargetOutcome {
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &nostr::Event,
        targets: &[String],
    ) -> haven_core::relay::RelayResult<haven_core::relay::PublishResult> {
        self.inner.publish_location(event, targets).await
    }
}

/// The most a relay that answers nothing is called by the live plane, hour
/// by hour, whatever wakes a drive and whichever lifecycle's drive finds the
/// relay due: an inbound storm, a drive after every event, and every minute
/// a foreground, a background burst and a session only started, each with a
/// drive of its own, in an order that changes from minute to minute. The
/// calls are the relay's own schedule and nothing else — seven in the first
/// hour, one in the second — and no event and no transition is answered
/// with a call of its own. A drive in which nothing is due takes no relay at
/// all, so it dials nothing. After its first send, which only the foreground
/// makes, the calls that fall due are made by bursts and by started
/// sessions as well: the schedule is the record's, not the caller's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_silent_relay_is_called_on_its_schedule_whatever_wakes_the_live_plane() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let transport = Arc::new(ScriptedFanout::default());
    let counting = Arc::new(Counting {
        inner: Arc::clone(&transport),
        takes: AtomicU64::new(0),
    });
    let clock = Clock::at(0);
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&counting) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true),
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    let plane = Plane {
        processor,
        transport: Arc::clone(&transport),
        unrecorded: Recording::acking(true),
        clock: Arc::clone(&clock),
        bus: EventBus::new().subscribe(),
    };
    plane.processor.for_test().set_background_burst(false);
    feed_leave(&plane, &fx, 1, 2).await;
    transport.answer(RELAY, [Answer::Silent]);
    let id = ngid(admin, &fx.group).await;

    let enter = |lifecycle: Lifecycle| match lifecycle {
        Lifecycle::Foreground => plane.processor.for_test().set_background_burst(false),
        Lifecycle::Burst => plane.processor.for_test().set_background_burst(true),
        _ => plane.processor.for_test().note_launched(),
    };
    let mut called_at = Vec::new();
    for minute in 0..120_u64 {
        clock.set(minute * 60 * SECOND_MS);
        let mut order = [Lifecycle::Foreground, Lifecycle::Burst, Lifecycle::Launched];
        order.rotate_left(usize::try_from(minute % 3).expect("small"));
        for lifecycle in order {
            enter(lifecycle);
            plane.processor.for_test().drive_due().await;
            for _ in transport.calls() {
                called_at.push((minute, lifecycle));
            }
        }
        if minute % 10 == 0 {
            enter(Lifecycle::Foreground);
            for _ in 0..3 {
                let inbound = sealed_by(&fx.members[2], &fx.group, 5.5).await;
                let takes_before = counting.takes.load(Ordering::SeqCst);
                plane.processor.process_group_event(&inbound, &id).await;
                assert_eq!(
                    counting.takes.load(Ordering::SeqCst),
                    takes_before,
                    "an inbound event took a relay by itself",
                );
                plane.processor.for_test().drive_due().await;
            }
            assert!(
                transport.calls().is_empty(),
                "a drive after an event called a relay that was not due",
            );
        }
    }

    assert_eq!(
        called_at,
        [
            (0, Lifecycle::Foreground),
            (1, Lifecycle::Burst),
            (2, Lifecycle::Launched),
            (4, Lifecycle::Burst),
            (8, Lifecycle::Launched),
            (16, Lifecycle::Burst),
            (32, Lifecycle::Launched),
            (64, Lifecycle::Burst),
        ],
        "the minutes a silent relay was called in over two hours, and by which lifecycle",
    );
    assert_eq!(
        counting.takes.load(Ordering::SeqCst),
        8,
        "a relay was taken for a drive in which it was not due",
    );
}

/// A clock that moves on a millisecond at every read, as a real one does
/// between two steps of a pass.
struct Ticking(AtomicU64);

impl FanoutClock for Ticking {
    fn now_ms(&self) -> u64 {
        self.0.fetch_add(1, Ordering::SeqCst)
    }
}

/// A burst's drive calls a relay that is due on a clock that moves. A pass
/// is begun with more than one row's budget, so that a whole row's worth is
/// still left at the moment a call is begun — on a real clock time has passed
/// between the two reads, and a pass given exactly one row's budget would
/// never call a relay at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bursts_drive_calls_a_due_relay_on_a_clock_that_moves() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let transport = Arc::new(ScriptedFanout::default());
    let clock = Arc::new(Ticking(AtomicU64::new(Clock::ORIGIN)));
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true),
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    processor.for_test().set_background_burst(false);
    feed_leave_to(&processor, &fx, 1, 2).await;
    transport.answer(RELAY, [Answer::Silent]);
    processor.for_test().drive_due().await;
    assert_eq!(transport.calls().len(), 1, "premise: sent once, unanswered");

    clock
        .0
        .store(Clock::ORIGIN + 3_600 * SECOND_MS, Ordering::SeqCst);
    processor.for_test().set_background_burst(true);
    transport.answer(RELAY, [Answer::Accepted]);
    processor.for_test().drive_due().await;
    assert!(
        transport.calls().len() == 1
            && staged_ref(admin, &fx.group).await.is_none()
            && !roster(admin, &fx.group)
                .await
                .contains(&fx.members[1].pubkey_hex()),
        "on a clock that moves a burst's drive did not call the relay that was due, or did \
         not confirm the commit it acknowledged",
    );
}

// ── One owner of a record, whichever driver finds it ─────────────────────────

/// A record staged by the live plane is one row of the session's store, and
/// whichever driver of the process finds it first has it: while the live
/// plane's call is on its way, a second driver over another transport — the
/// sweep that drives, a send-side entry — finds the row busy and sends
/// nothing, and no publish pool of the process will send its event.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_record_the_live_plane_is_driving_is_sent_by_no_other_driver_or_pool() {
    let (fx, plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    let admin = fx.admin();
    let event_id = records_of(admin, &fx.group).await[0].event_id;
    plane.transport.park();
    let pass = plane.processor.for_test().drive_due();
    tokio::pin!(pass);
    tokio::select! {
        biased;
        () = &mut pass => panic!("the drive finished while its call was parked"),
        () = plane.transport.parked() => {}
    }

    let elsewhere = ScriptedFanout::default();
    elsewhere.answer(RELAY, [Answer::Accepted]);
    let other_clock = Clock::at(0);
    let other_publisher = Recording::acking(true);
    let second: Publishing<'_, dyn FanoutSend> = Publishing {
        fanout: &elsewhere,
        publisher: other_publisher.as_ref(),
        clock: other_clock.as_ref(),
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let begun = standing_of(admin, &fx.group).await;
    let _ = second.resume(&admin.circle).await;
    assert_eq!(
        elsewhere.call_count(),
        0,
        "a second driver sent a record another drive of this process had",
    );
    assert_eq!(
        standing_of(admin, &fx.group).await,
        begun,
        "a second driver wrote over an attempt another drive of this process had begun",
    );
    assert!(haven_core::relay::fanout::is_owned(&event_id));
    assert!(other_publisher.handed().is_empty());

    plane.transport.unpark();
    pass.await;
    assert_eq!(plane.transport.most_at_once(), 1);
}

// ── The foreground ends under a pass ─────────────────────────────────────────

/// A member's invite recorded for `RELAY` and never sent, on the admin's
/// device: the relay could not be had when it was made.
async fn an_invite_recorded_and_unsent(
    fx: &CircleFixture,
    joiner: &CircleMember,
) -> haven_core::relay::fanout::EvolutionStatus {
    let inbox = vec!["wss://inbox.live-canary7d2f.example.com".to_string()];
    let invited = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            joiner.session(),
            &joiner.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox,
        nip65_relays: Vec::new(),
    };
    let busy = ScriptedFanout::default();
    busy.answer(RELAY, [Answer::Busy]);
    let nobody = Recording::acking(true);
    let clock = Clock::at(0);
    Publishing {
        fanout: &busy,
        publisher: nobody.as_ref(),
        clock: clock.as_ref(),
        deadline_ms: None,
        mode: &DriveMode::Full,
    }
    .add_members(&fx.admin().circle, &fx.group, &[invited])
    .await
    .expect("the invite is accepted")
    .status
}

/// The foreground ends while a drive has its call out, and the relay's
/// acknowledgement arrives after it. The pass is finish-only from the flip: it
/// stores the acknowledgement and does nothing else — the commit is not
/// applied, and no Welcome is released, not even when the foreground has
/// come back before the answer: what the pass may do was decided when the
/// foreground ended. The next foreground drive confirms it without calling a
/// relay, and delivers the Welcome then.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_acknowledgement_that_arrives_after_the_foreground_ended_releases_no_welcome_until_the_next(
) {
    for returns in [false, true] {
        let fx = setup_circle(2, &[RELAY]).await;
        let admin = fx.admin();
        let joiner = CircleMember::new();
        assert_eq!(
            an_invite_recorded_and_unsent(&fx, &joiner).await,
            haven_core::relay::fanout::EvolutionStatus::Unresolved,
            "premise",
        );
        let plane = Plane::over(&admin.circle);
        plane.processor.for_test().set_background_burst(false);
        plane.transport.answer(RELAY, [Answer::Accepted]);
        plane.transport.park();
        {
            let pass = plane.processor.for_test().drive_due();
            tokio::pin!(pass);
            tokio::select! {
                biased;
                () = &mut pass => panic!("the drive finished while its call was parked"),
                () = plane.transport.parked() => {}
            }
            // The pause flips the lifecycle; then the relay answers — in the
            // second run, after the foreground has come back.
            plane.processor.for_test().leave_foreground();
            if returns {
                plane.processor.for_test().set_background_burst(false);
            }
            plane.transport.unpark();
            pass.await;
        }
        let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
            .unwrap_or_else(|_| panic!("the invite has one record"));
        assert_eq!(
            (record.mls, record.statuses.as_slice(), record.held_welcomes),
            (FanoutMls::Pending, &[FanoutTargetStatus::Accepted][..], 1),
            "a pass that outlived the foreground confirmed, or lost the relay's answer \
             (returns={returns})",
        );
        assert!(
            plane.unrecorded.handed().is_empty(),
            "a Welcome was released after the foreground ended",
        );
        plane.transport.calls();

        plane.processor.for_test().set_background_burst(false);
        plane.processor.for_test().drive_due().await;
        assert_eq!(
            plane.transport.call_count(),
            0,
            "confirming a stored acknowledgement called a relay again",
        );
        assert!(
            records_of(admin, &fx.group)
                .await
                .iter()
                .all(|record| record.mls == FanoutMls::Confirmed),
            "the next foreground drive did not confirm the stored acknowledgement",
        );
        assert!(roster(admin, &fx.group)
            .await
            .contains(&joiner.pubkey_hex()));
        assert!(
            plane
                .unrecorded
                .handed()
                .iter()
                .any(|event| event.kind == Kind::GiftWrap),
            "the next foreground drive did not deliver the Welcome",
        );
    }
}

/// A Welcome released by a pass that then outlives the foreground keeps its
/// route. An invite is applied with its Welcome still held, and a second
/// change of the circle awaits its relay. The next foreground pass releases
/// the Welcome, then calls the relay for the second change, and the
/// foreground ends under that call. Nothing is published after it, and the
/// next foreground drive delivers the Welcome: a route spent on a send that
/// was never made would lock the invitee out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_released_before_the_foreground_ended_keeps_its_route_for_the_next() {
    use haven_core::relay::fanout::{EvolutionStatus, ROW_BUDGET_MS};

    let fx = setup_circle(2, &[RELAY]).await;
    let admin = fx.admin();
    let joiner = CircleMember::new();
    let inbox = vec!["wss://inbox.live-canary7d2f.example.com".to_string()];
    let invited = haven_core::circle::MemberKeyPackage {
        key_package_event: helpers::create_key_package_event(
            joiner.session(),
            &joiner.keys,
            &inbox,
        )
        .await,
        inbox_relays: inbox,
        nip65_relays: Vec::new(),
    };
    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(RELAY, [Answer::Accepted, Answer::Unreachable]);
    let nobody = Recording::acking(true);
    let clock = Clock::at(0);
    // Wakes with room for a commit's row and none for a Welcome.
    let staging = Publishing {
        fanout: transport.as_ref(),
        publisher: nobody.as_ref(),
        clock: clock.as_ref(),
        deadline_ms: Some(clock.now_ms() + ROW_BUDGET_MS),
        mode: &DriveMode::Full,
    };
    let invite = staging
        .add_members(&admin.circle, &fx.group, &[invited])
        .await
        .expect("the invite is accepted");
    let second = staging
        .update_relays(
            &admin.circle,
            &fx.group,
            &[RELAY.to_string(), OTHER.to_string()],
        )
        .await
        .expect("the relay change is accepted");
    assert_eq!(
        (
            invite.status,
            second.status,
            invite.welcomes_sent + second.welcomes_sent,
            nobody.handed().len()
        ),
        (
            EvolutionStatus::Confirmed,
            EvolutionStatus::Unresolved,
            0,
            0
        ),
        "premise: the invite applied with its Welcome held, a second change awaiting",
    );
    transport.calls();

    clock.set(3_600 * SECOND_MS);
    transport.answer(RELAY, [Answer::Accepted]);
    transport.park();
    let plane = Plane::with(&admin.circle, Arc::clone(&transport), Arc::clone(&clock));
    plane.processor.for_test().set_background_burst(false);
    {
        let pass = plane.processor.for_test().drive_due();
        tokio::pin!(pass);
        tokio::select! {
            biased;
            () = &mut pass => panic!("the drive finished while its call was parked"),
            () = transport.parked() => {}
        }
        plane.processor.for_test().leave_foreground();
        transport.unpark();
        pass.await;
    }
    assert!(
        plane.unrecorded.handed().is_empty(),
        "a Welcome was published after the foreground ended",
    );

    plane.processor.for_test().set_background_burst(false);
    plane.processor.for_test().drive_due().await;
    assert!(
        plane
            .unrecorded
            .handed()
            .iter()
            .any(|event| event.kind == Kind::GiftWrap),
        "the Welcome's route was spent by the pass that outlived the foreground",
    );
}

/// A background burst opens over a pass that has its call out. Whatever the
/// relay then proves, the pass rolls nothing back, applies no bound and
/// records nothing: it is finish-only from the flip, so the burst meets a pass
/// that can no longer do what a burst must not. The next foreground drive
/// does what the stored answers allow.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pass_in_flight_when_a_burst_opens_rolls_nothing_back_and_applies_no_bound() {
    const DAY_MS: u64 = 24 * 3_600 * SECOND_MS;
    for (later_ms, answer) in [
        (6 * SECOND_MS, Answer::Refused),
        (DAY_MS + 3_600 * SECOND_MS, Answer::Unreachable),
    ] {
        let fx = setup_circle(3, &[RELAY]).await;
        let admin = fx.admin();
        // A change that removes nobody, its first call unreachable: nothing
        // is exposed, so a full drive may undo it on proof or at its bound.
        let first = ScriptedFanout::default();
        first.answer(RELAY, [Answer::Unreachable]);
        let nobody = Recording::acking(true);
        let clock = Clock::at(0);
        let staged = Publishing {
            fanout: &first,
            publisher: nobody.as_ref(),
            clock: clock.as_ref(),
            deadline_ms: None,
            mode: &DriveMode::Full,
        }
        .admin_handoff(&admin.circle, &fx.group, &fx.members[2].keys.public_key())
        .await
        .expect("the hand-over is accepted");
        assert_eq!(
            staged.status,
            haven_core::relay::fanout::EvolutionStatus::Unresolved,
            "premise",
        );

        let transport = Arc::new(ScriptedFanout::default());
        transport.answer(RELAY, [answer]);
        transport.park();
        clock.set(later_ms);
        let plane = Plane::with(&admin.circle, Arc::clone(&transport), Arc::clone(&clock));
        plane.processor.for_test().set_background_burst(false);
        {
            let pass = plane.processor.for_test().drive_due();
            tokio::pin!(pass);
            tokio::select! {
                biased;
                () = &mut pass => panic!("the drive finished while its call was parked"),
                () = transport.parked() => {}
            }
            // The burst opens over the pass; then the relay answers.
            plane.processor.for_test().set_background_burst(true);
            transport.unpark();
            pass.await;
        }
        let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
            .unwrap_or_else(|_| panic!("the pass wrote a record, or removed the one it drove"));
        assert_eq!(record.mls, FanoutMls::Pending);
        assert!(
            staged_ref(admin, &fx.group).await.is_some()
                && admin.session().peek_change_notes(&fx.group).is_empty()
                && plane.unrecorded.handed().is_empty(),
            "a pass in flight when a burst opened rolled back, applied the bound or published",
        );

        // The full mode's, at the next foreground.
        transport.calls();
        plane.processor.for_test().set_background_burst(false);
        plane.processor.for_test().drive_due().await;
        assert!(
            staged_ref(admin, &fx.group).await.is_none()
                && admin.session().peek_change_notes(&fx.group) == [ChangeNote::ChangeUndone],
            "premise: a full drive undoes what the stored answers allow",
        );
    }
}

/// A pass that outlives the foreground ends no record. A change is applied
/// on one relay's word with two still owed; the next foreground pass calls
/// them, the foreground ends under those calls, and both then take the
/// event. The answers are stored and the record is left for a full drive,
/// which ends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pass_that_outlived_the_foreground_ends_no_record() {
    const THIRD: &str = "wss://three.live-canary7d2f.example.com";
    let fx = setup_circle(3, &[RELAY, OTHER, THIRD]).await;
    let admin = fx.admin();
    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(RELAY, [Answer::Accepted]);
    for relay in [OTHER, THIRD] {
        transport.answer(relay, [Answer::Unreachable]);
    }
    let nobody = Recording::acking(true);
    let clock = Clock::at(0);
    let applied = Publishing {
        fanout: transport.as_ref(),
        publisher: nobody.as_ref(),
        clock: clock.as_ref(),
        deadline_ms: None,
        mode: &DriveMode::Full,
    }
    .admin_handoff(&admin.circle, &fx.group, &fx.members[2].keys.public_key())
    .await
    .expect("the hand-over is accepted");
    assert_eq!(
        applied.status,
        haven_core::relay::fanout::EvolutionStatus::Confirmed,
        "premise: applied on one relay's word",
    );
    assert_eq!(
        records_of(admin, &fx.group).await.len(),
        1,
        "premise: its record stays for the two relays still owed",
    );
    transport.calls();

    clock.set(3_600 * SECOND_MS);
    for relay in [OTHER, THIRD] {
        transport.answer(relay, [Answer::Accepted]);
    }
    transport.park();
    let plane = Plane::with(&admin.circle, Arc::clone(&transport), Arc::clone(&clock));
    plane.processor.for_test().set_background_burst(false);
    {
        let pass = plane.processor.for_test().drive_due();
        tokio::pin!(pass);
        tokio::select! {
            biased;
            () = &mut pass => panic!("the drive finished while its call was parked"),
            () = transport.parked() => {}
        }
        plane.processor.for_test().leave_foreground();
        transport.unpark();
        pass.await;
    }
    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("a pass that outlived the foreground ended a record"));
    assert!(
        record
            .statuses
            .iter()
            .all(|status| *status == FanoutTargetStatus::Accepted),
        "the answers of the calls that were out were not stored",
    );

    plane.processor.for_test().set_background_burst(false);
    plane.processor.for_test().drive_due().await;
    assert!(
        records_of(admin, &fx.group).await.is_empty(),
        "premise: a full drive ends a record every relay has taken",
    );
}

/// The poll entry gives a queued change its attempt, whatever it was called
/// for: a fix polled in a quiet circle that holds a queued removal releases
/// the removal, which is recorded and sent in the same call. A finish-only
/// call makes no such attempt.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_queued_in_a_quiet_circle_is_given_its_attempt_by_a_full_poll() {
    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let transport = ScriptedFanout::default();
    transport.answer(RELAY, [Answer::Accepted]);
    let nobody = Recording::acking(true);
    let clock = Clock::at(0);
    let polled = |mode: &'static DriveMode, latitude: f64| {
        let (transport, nobody, clock, fx) = (&transport, &nobody, &clock, &fx);
        async move {
            let fix = helpers::drive::sealed_by(&fx.alice, &fx.group, latitude).await;
            Publishing {
                fanout: transport,
                publisher: nobody.as_ref(),
                clock: clock.as_ref(),
                deadline_ms: Some(clock.now_ms() + 2 * haven_core::relay::fanout::ROW_BUDGET_MS),
                mode,
            }
            .ingest_for_poll(&fx.bob.circle, &fix)
            .await
            .expect("the polled fix is ingested")
        }
    };

    let _ = polled(&DriveMode::FinishOnly, 10.0).await;
    assert_eq!(
        (queue_len(&fx.bob, &fx.group).await, transport.call_count()),
        (1, 0),
        "a finish-only poll made a queued change",
    );

    let _ = polled(&DriveMode::Full, 11.0).await;
    assert_eq!(
        (queue_len(&fx.bob, &fx.group).await, transport.calls().len()),
        (0, 1),
        "a full poll left a queued change standing, or did not send what it released",
    );
    assert!(
        !roster(&fx.bob, &fx.group)
            .await
            .contains(&fx.carol.pubkey_hex()),
        "the removal the user asked for was not made",
    );
}

/// A poll whose wake has less than a fold's budget left ingests its event
/// and advances nothing: an advance waits out the engine's own deadlines,
/// and a wake that could not see it through must not begin it. The queued
/// change keeps waiting, no relay is called, and the answer says the wake
/// ran out. The next poll with the budget gives the change its attempt.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_poll_with_no_room_for_an_advance_makes_none_and_says_the_wake_ran_out() {
    use haven_core::relay::fanout::{FOLD_BUDGET_MS, ROW_BUDGET_MS};

    let fx = a_removal_left_queued_behind_a_closed_pass().await;
    let transport = ScriptedFanout::default();
    transport.answer(RELAY, [Answer::Accepted]);
    let nobody = Recording::acking(true);
    let clock = Clock::at(0);
    let polled = |room_ms: u64, latitude: f64| {
        let (transport, nobody, clock, fx) = (&transport, &nobody, &clock, &fx);
        async move {
            let fix = helpers::drive::sealed_by(&fx.alice, &fx.group, latitude).await;
            Publishing {
                fanout: transport,
                publisher: nobody.as_ref(),
                clock: clock.as_ref(),
                deadline_ms: Some(clock.now_ms() + room_ms),
                mode: &DriveMode::Full,
            }
            .ingest_for_poll(&fx.bob.circle, &fix)
            .await
            .expect("the polled fix is ingested")
        }
    };

    let short = polled(FOLD_BUDGET_MS - 1, 10.0).await;
    assert_eq!(
        (
            queue_len(&fx.bob, &fx.group).await,
            transport.call_count(),
            short.retry_after_ms,
        ),
        (1, 0, Some(0)),
        "a poll with no room for an advance made one, or did not say the wake ran out",
    );
    assert!(staged_ref(&fx.bob, &fx.group).await.is_none());

    let roomy = polled(2 * ROW_BUDGET_MS, 11.0).await;
    assert_eq!(
        (queue_len(&fx.bob, &fx.group).await, transport.calls().len()),
        (0, 1),
        "control: a poll with the budget gives the queued change its attempt",
    );
    assert_ne!(roomy.retry_after_ms, Some(0));
}

// ── The burst's end ──────────────────────────────────────────────────────────

/// A background burst's end bounds every wake begun inside it — the plane's
/// own drive and every call the bridge makes — and nothing else: a
/// foreground has its whole budget again, a plane let go in a burst leaves
/// no end behind, and an older plane's word does not clear a newer one's.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_bounds_every_drive_the_bridge_begins_inside_it() {
    use haven_core::relay::fanout::{wake_deadline, RESUME_BUDGET_MS};
    let member = CircleMember::new();
    let clock = Clock::at(0);
    let plane = Plane::with(
        &member.circle,
        Arc::new(ScriptedFanout::default()),
        Arc::clone(&clock),
    );
    let now = clock.now_ms();
    let whole = now + RESUME_BUDGET_MS;
    let deadline = || wake_deadline(&member.circle, &*clock, RESUME_BUDGET_MS);
    assert_eq!(deadline(), whole, "premise: no burst, the whole budget");

    plane.processor.for_test().set_background_burst(true);
    plane
        .processor
        .for_test()
        .set_burst_budget(Some(10 * SECOND_MS));
    let cut = deadline();
    assert!(
        cut > now && cut <= now + 10 * SECOND_MS,
        "a wake begun inside the burst is not cut at the burst's end",
    );

    plane.processor.for_test().set_background_burst(false);
    assert_eq!(deadline(), whole, "the burst's end outlived the burst");

    plane.processor.for_test().set_background_burst(true);
    plane
        .processor
        .for_test()
        .set_burst_budget(Some(10 * SECOND_MS));
    drop(plane);
    assert_eq!(
        deadline(),
        whole,
        "a plane let go in a burst left its end behind"
    );

    let older = Plane::with(
        &member.circle,
        Arc::new(ScriptedFanout::default()),
        Arc::clone(&clock),
    );
    let newer = Plane::with(
        &member.circle,
        Arc::new(ScriptedFanout::default()),
        Arc::clone(&clock),
    );
    newer.processor.for_test().set_background_burst(true);
    newer
        .processor
        .for_test()
        .set_burst_budget(Some(10 * SECOND_MS));
    older.processor.for_test().set_background_burst(false);
    drop(older);
    assert!(
        deadline() <= now + 10 * SECOND_MS,
        "an older plane's word cleared the burst a newer plane is in",
    );
    drop(newer);
}

/// A network return — the live pool lost every relay and has one back —
/// makes a relay a pending record could not reach due at once, and asks for
/// the drive that calls it. At most once a minute on the driver's clock, so
/// a flapping network calls such a relay no more often than that; and never
/// in a lifecycle that does not drive on a timer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_network_return_makes_unreachable_relays_due_at_once_and_at_most_once_a_minute() {
    use haven_core::relay::live_sync::NETWORK_BACK_FLOOR_MS;
    let (_fx, plane) = an_eviction_recorded_in_the_foreground(&[RELAY]).await;
    plane.transport.answer(RELAY, [Answer::Unreachable; 12]);
    let drive_at = |at_ms: u64| {
        plane.clock.set(at_ms);
        plane.processor.for_test().drive_due()
    };
    // Unreachable six times in a row: the relay now waits two minutes.
    for at_ms in [0, 5, 10, 15, 45, 105] {
        drive_at(at_ms * SECOND_MS).await;
    }
    assert_eq!(plane.transport.calls().len(), 6, "premise: six calls");
    assert!(
        plane
            .processor
            .drive_retry_after_ms()
            .is_some_and(|wait| wait > NETWORK_BACK_FLOOR_MS),
        "premise: the relay waits longer than the floor",
    );
    let _ = plane.processor.for_test().drive_was_requested();
    let back = 105 * SECOND_MS;

    plane.processor.for_test().network_back().await;
    assert!(
        plane.processor.for_test().drive_was_requested(),
        "a network return asked for no drive"
    );
    drive_at(back).await;
    assert_eq!(
        plane.transport.calls().len(),
        1,
        "the relay that could not be reached was not called at once",
    );

    plane.processor.for_test().network_back().await;
    plane.clock.set(back + NETWORK_BACK_FLOOR_MS - 1);
    plane.processor.for_test().network_back().await;
    assert!(
        !plane.processor.for_test().drive_was_requested(),
        "a second network return within the floor asked for a drive",
    );
    drive_at(back + NETWORK_BACK_FLOOR_MS - 1).await;
    assert_eq!(
        plane.transport.calls().len(),
        0,
        "a second network return within the floor called the relay again",
    );

    plane.clock.set(back + NETWORK_BACK_FLOOR_MS);
    plane.processor.for_test().network_back().await;
    assert!(
        plane.processor.for_test().drive_was_requested(),
        "a network return a floor later asked for no drive"
    );
    drive_at(back + NETWORK_BACK_FLOOR_MS).await;
    assert_eq!(
        plane.transport.calls().len(),
        1,
        "a network return a floor later did not call the relay",
    );

    plane.processor.for_test().leave_foreground();
    plane.clock.set(back + 10 * NETWORK_BACK_FLOOR_MS);
    plane.processor.for_test().network_back().await;
    assert!(
        !plane.processor.for_test().drive_was_requested(),
        "a network return asked for a drive while paused",
    );
}

// ── The drive's own timer ────────────────────────────────────────────────────

/// After a call a relay never answered, nothing else wakes the plane — no
/// event, no tick. The drive task's own timer falls due when the relay's
/// schedule does, on the driver's clock, and the drive it wakes makes the
/// second call then and not before. It arms nothing with no hint, and
/// nothing once the foreground has ended.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drive_left_waiting_on_a_silent_relay_wakes_itself_when_that_relay_is_due() {
    use helpers::drive::ManualClock;

    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    // Staged on the plane's usual fixture clock, then driven on one whose
    // waits end only when the test moves it.
    let staging = Plane::over(&admin.circle);
    staging.processor.for_test().set_background_burst(false);
    feed_leave(&staging, &fx, 1, 2).await;
    drop(staging);

    let transport = Arc::new(ScriptedFanout::default());
    let clock = ManualClock::at(0);
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    // No hint yet: nothing to wake for.
    processor.for_test().set_background_burst(false);
    assert!(futures::poll!(std::pin::pin!(processor.drive_due_again())).is_pending());

    processor.for_test().drive_due().await;
    assert_eq!(transport.calls().len(), 1, "premise: the first call");
    assert_eq!(processor.drive_retry_after_ms(), Some(30 * SECOND_MS));
    {
        let timer = processor.drive_due_again();
        tokio::pin!(timer);
        assert!(futures::poll!(&mut timer).is_pending());
        clock.set(29 * SECOND_MS);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_pending(),
            "the drive woke itself before the relay was due",
        );
        clock.set(30 * SECOND_MS);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_ready(),
            "the drive did not wake itself when the relay fell due",
        );
    }
    processor.for_test().drive_due().await;
    assert_eq!(
        transport.calls().len(),
        1,
        "the drive its own timer woke did not make the relay's second call",
    );

    // The foreground ends: the timer arms nothing, wherever the clock goes,
    // and nothing is left of it when the foreground returns — the open asks
    // for its own drive.
    assert!(processor.drive_retry_after_ms().is_some(), "premise");
    processor.for_test().leave_foreground();
    clock.set(3_600 * SECOND_MS);
    assert!(
        futures::poll!(std::pin::pin!(processor.drive_due_again())).is_pending(),
        "the drive timer fell due outside the foreground",
    );
    processor.for_test().set_background_burst(false);
    assert!(
        futures::poll!(std::pin::pin!(processor.drive_due_again())).is_pending(),
        "a time left over from an earlier foreground woke the drive",
    );

    // Inside a background burst the timer is armed as in the foreground: a
    // burst's drive that left a relay waiting wakes itself for it.
    processor.for_test().set_background_burst(true);
    processor.for_test().drive_due().await;
    assert_eq!(transport.calls().len(), 1, "premise: a burst's call");
    let wait = processor
        .drive_retry_after_ms()
        .expect("premise: a burst's drive says when its relay is next due");
    {
        let timer = processor.drive_due_again();
        tokio::pin!(timer);
        assert!(futures::poll!(&mut timer).is_pending());
        clock.set(3_600 * SECOND_MS + wait);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_ready(),
            "a burst's drive did not wake itself when its relay fell due",
        );
    }

    // A session only started runs the one drive its start asks for and arms
    // nothing: it is in a process nobody may be looking at, with no burst
    // to end it, and a timer there is a standing contact with a relay.
    processor.for_test().note_launched();
    processor.for_test().drive_due().await;
    assert!(
        transport.calls().len() == 1 && processor.drive_retry_after_ms().is_some(),
        "premise: a started session's one drive called the relay that was due",
    );
    clock.set(100_000 * SECOND_MS);
    tokio::task::yield_now().await;
    assert!(
        futures::poll!(std::pin::pin!(processor.drive_due_again())).is_pending(),
        "a session only started armed a drive timer",
    );
}

/// A commit whose first call left nothing proven — the relay took it and
/// its `OK` never came — is confirmed in a live foreground with nothing else
/// waking the plane: no claim, no request, no resume. The drive task's own
/// timer falls due when the relay's schedule does, and that drive's
/// acknowledgement applies the commit and releases the circle's sends (Rule
/// 13.4).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_swallowed_ok_evolution_confirms_in_a_live_sync_foreground_without_a_resume() {
    use haven_core::relay::fanout::scripted::Inert;
    use helpers::drive::ManualClock;

    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let staging = Plane::over(&admin.circle);
    staging.processor.for_test().set_background_burst(false);
    feed_leave(&staging, &fx, 1, 2).await;
    drop(staging);
    let leaver = fx.members[1].pubkey_hex();
    // The epoch the staged removal takes the circle to.
    let epoch = admin.session().epoch(&fx.group).await.expect("epoch");

    let transport = Arc::new(ScriptedFanout::default());
    transport.answer(RELAY, [Answer::Silent, Answer::Accepted]);
    let clock = ManualClock::at(0);
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    processor.for_test().set_background_burst(false);
    let seal = || async {
        Publishing::<'_, Inert> {
            fanout: &Inert,
            publisher: &Inert,
            clock: &*clock,
            deadline_ms: None,
            mode: &DriveMode::FinishOnly,
        }
        .seal_location(&admin.circle, &fx.group, &LocationMessage::new(1.0, 2.0))
        .await
        .expect("the send is answered")
        .seal
    };

    processor.for_test().drive_due().await;
    assert_eq!(transport.calls().len(), 1, "premise: the first call");
    assert!(
        staged_ref(admin, &fx.group).await.is_some(),
        "premise: a swallowed OK leaves the removal unresolved",
    );
    assert!(
        matches!(
            seal().await,
            LocationSeal::Deferred(SendHeld::AwaitingRelays)
        ),
        "premise: the circle's sends wait for the commit",
    );
    let wait = processor
        .drive_retry_after_ms()
        .expect("the drive says when the relay is next due");
    {
        let timer = processor.drive_due_again();
        tokio::pin!(timer);
        clock.set(wait - 1);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_pending(),
            "the drive woke itself before the relay was due",
        );
        clock.set(wait);
        tokio::task::yield_now().await;
        assert!(
            futures::poll!(&mut timer).is_ready(),
            "nothing woke the live foreground when the relay fell due",
        );
    }
    processor.for_test().drive_due().await;

    assert_eq!(
        transport.calls().len(),
        1,
        "the due drive did not call the relay"
    );
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && !roster(admin, &fx.group).await.contains(&leaver),
        "the acknowledged removal was not applied",
    );
    assert!(
        matches!(
            admin.session().epoch_state(&fx.group).await,
            Some(EpochState::Stable { epoch: now }) if now.0 == epoch
        ),
        "the circle did not move to the epoch its removal staged",
    );
    assert!(
        matches!(seal().await, LocationSeal::Sealed { .. }),
        "the circle's sends are still held after the commit was applied",
    );
}

/// A session only started stages nothing at its open. An eviction a
/// background plane left due is re-armed by the engine when the process
/// starts again and is due long before the open's connect wait is over; the
/// open-time advance runs before any REQ, in a process a start cannot tell
/// from a background cold launch, and made in full it would stage that
/// eviction from an epoch the circle may have left. It settles what is
/// stored and stages nothing. The claim's drive then makes the eviction, under a record.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_only_started_stages_nothing_at_its_open_and_the_claims_drive_makes_what_is_due()
{
    let fx = setup_circle(3, &[RELAY]).await;
    let leave = helpers::drive::leave_of(&fx, 1).await;
    helpers::drive::make_a_departure_due(fx.admin(), &fx.members[2], &fx.group, &leave).await;
    let CircleFixture { mut members, group } = fx;
    let leaver = members[1].pubkey_hex();
    // The process ends, with the eviction due and unmade.
    let admin = members.remove(0).reopen();
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&group);

    let plane = Plane::over(&admin.circle);
    assert_eq!(plane.processor.lifecycle(), Lifecycle::Launched);
    plane.processor.drain_open_advance().await;
    helpers::drive::wait_out_the_engine(&admin, &group).await;
    assert!(
        staged_ref(&admin, &group).await.is_none()
            && records_of(&admin, &group).await.is_empty()
            && plane.transport.call_count() == 0
            && roster(&admin, &group).await.contains(&leaver),
        "a session only started staged, published or owed an eviction at its open",
    );

    assert!(plane.processor.for_test().prove_foreground(), "the claim");
    plane.transport.answer(RELAY, [Answer::Accepted]);
    plane.processor.for_test().drive_due().await;
    assert!(
        plane.transport.call_count() == 1 && !roster(&admin, &group).await.contains(&leaver),
        "the claim's drive did not make the eviction that was due, under a record",
    );
}

/// A pause that lands while an event waits for the engine: the plane read
/// its lifecycle as the foreground's when the event arrived, and by the time
/// it has the engine the foreground has ended. What the event leaves owing
/// is then settled as a plane that makes no commit settles it — the full
/// advance, which would stage the eviction of the member who left and
/// record it behind the pause, is not made. The foreground that follows
/// makes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pause_that_lands_while_an_event_waits_for_the_engine_stages_nothing() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    // Caught up, as a sweep or the live plane's end of stored events makes it.
    admin.session().mark_caught_up_for_test(&fx.group);
    let plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    let id = ngid(admin, &fx.group).await;
    let leave = helpers::drive::leave_of(&fx, 1).await;
    let leaver = fx.members[1].pubkey_hex();

    {
        let engine = admin.session().hold_session_for_test().await;
        let arriving = plane.processor.process_group_event(&leave, &id);
        tokio::pin!(arriving);
        assert!(
            futures::poll!(&mut arriving).is_pending(),
            "premise: the event waits for the engine",
        );
        plane.processor.for_test().leave_foreground();
        drop(engine);
        let _ = arriving.await;
    }
    helpers::drive::wait_out_the_engine(admin, &fx.group).await;
    assert!(
        staged_ref(admin, &fx.group).await.is_none()
            && records_of(admin, &fx.group).await.is_empty()
            && plane.transport.call_count() == 0
            && roster(admin, &fx.group).await.contains(&leaver),
        "an eviction was staged behind a pause, by a plane that read the foreground before \
         it had the engine",
    );
    assert!(
        admin
            .session()
            .eviction_due_after_for_test(&fx.group)
            .await
            .is_some(),
        "premise: the leave was taken in, and its eviction is the next foreground's",
    );

    plane.processor.for_test().set_background_burst(false);
    plane.transport.answer(RELAY, [Answer::Accepted]);
    plane.processor.for_test().drive_due().await;
    assert!(
        plane.transport.call_count() == 1 && !roster(admin, &fx.group).await.contains(&leaver),
        "control: the foreground that follows makes the eviction",
    );
}

// ── The foreground is a claim ────────────────────────────────────────────────

/// A clock that counts how often it is read. A drive reads it once its
/// lifecycle has answered yes, and nothing else in an idle session does.
struct ReadCounted {
    inner: Arc<helpers::drive::ManualClock>,
    reads: AtomicU64,
}

impl ReadCounted {
    fn over(inner: &Arc<helpers::drive::ManualClock>) -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::clone(inner),
            reads: AtomicU64::new(0),
        })
    }

    fn reads(&self) -> u64 {
        self.reads.load(Ordering::SeqCst)
    }
}

impl FanoutClock for ReadCounted {
    fn now_ms(&self) -> u64 {
        self.reads.fetch_add(1, Ordering::SeqCst);
        self.inner.now_ms()
    }

    fn until<'a>(&'a self, at_ms: u64) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        self.inner.until(at_ms)
    }
}

/// What a real session's drives go through in these tests: the scripted
/// transport behind a count of every relay taken, a publisher that only
/// records, and a clock the test sets and can see being read.
struct Scripted {
    transport: Arc<ScriptedFanout>,
    counting: Arc<Counting>,
    outbox: Arc<Recording>,
    clock: Arc<helpers::drive::ManualClock>,
    read: Arc<ReadCounted>,
}

impl Scripted {
    fn new() -> Self {
        let transport = Arc::new(ScriptedFanout::default());
        let clock = helpers::drive::ManualClock::at(0);
        Self {
            counting: Arc::new(Counting {
                inner: Arc::clone(&transport),
                takes: AtomicU64::new(0),
            }),
            transport,
            outbox: Recording::acking(true),
            read: ReadCounted::over(&clock),
            clock,
        }
    }

    fn driver(&self) -> LiveDriver {
        LiveDriver {
            fanout: Arc::clone(&self.counting) as Arc<dyn FanoutSend>,
            publisher: Arc::clone(&self.outbox) as Arc<dyn UnrecordedPublisher>,
            clock: Arc::clone(&self.read) as Arc<dyn FanoutClock>,
        }
    }

    /// Starts a real session for `member` over `scripted`, its engine
    /// subscribed at `relay`, and makes the caller's `claim` for it once it
    /// has started, as the app does.
    async fn session(
        &self,
        member: &CircleMember,
        group: &GroupId,
        relay: &str,
        claim: Claim,
    ) -> LiveSyncCore {
        let core = LiveSyncCore::new_local_with_driver_for_test(
            Arc::clone(&member.circle),
            member.keys.public_key(),
            self.driver(),
        );
        let spec = CircleSpec {
            group_id_hex: hex::encode(ngid(member, group).await),
            relays: vec![relay.to_owned()],
        };
        core.start(&[spec], &[]).await.expect("the session starts");
        core.claim_foreground(claim).await;
        core
    }

    /// Waits until a drive of `core` that got as far as reading the clock
    /// after `reads_before` has ended, and answers whether one did.
    async fn a_drive_ran(&self, core: &LiveSyncCore, reads_before: u64) -> bool {
        held(|| async { self.read.reads() > reads_before && core.in_flight_publishes() == 0 }).await
    }
}

/// Asks `question` until it answers yes, for at most ten seconds, and
/// answers whether it did. The answer decides; the interval only spaces the
/// asking, so a slow machine waits longer and cannot change the verdict.
async fn held<F, Fut>(question: F) -> bool
where
    F: Fn() -> Fut,
    Fut: Future<Output = bool>,
{
    for _ in 0..400 {
        if question().await {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    false
}

/// A circle whose routing names an in-process relay, with that relay: the
/// address a session's engine subscribes at and the one its records target.
async fn a_circle_on_a_local_relay() -> (CircleFixture, MockRelay, String) {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    (setup_circle(3, &[&url]).await, relay, url)
}

/// A session its caller claims the foreground for once it has started is in
/// it from that claim, and the claim asks for the one drive that begins
/// there: a record stored and due — recorded by an earlier process, never
/// sent — is sent at once, through the fanout transport, with nothing else
/// arriving.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_claim_behind_a_start_drives_a_stored_due_record_at_once() {
    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let earlier = Plane::over(&admin.circle);
    earlier.processor.for_test().set_background_burst(false);
    let leave = feed_leave(&earlier, &fx, 1, 2).await;
    drop(earlier);
    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("premise: one stored record"));
    assert!(record.attempts.iter().all(|attempts| *attempts == 0));

    let scripted = Scripted::new();
    scripted.transport.answer(&url, [Answer::Accepted]);
    let core = scripted
        .session(admin, &fx.group, &url, Claim::Foreground)
        .await;
    assert_eq!(core.processor().lifecycle(), Lifecycle::Foreground);
    assert!(
        held(|| async { records_of(admin, &fx.group).await.is_empty() }).await,
        "a claim made behind a start left a stored, due record unsent",
    );

    let calls = scripted.transport.calls();
    assert_eq!(calls.len(), 1, "the stored record was not sent once");
    assert_eq!(calls[0].event_id, record.event_id);
    assert!(scripted.outbox.handed().is_empty());
    let eviction = Event::from_json(&calls[0].payload).expect("a signed event");
    assert_the_eviction_removed(
        admin,
        &fx.members[2],
        &fx.members[1],
        &fx.group,
        &leave,
        &eviction,
    )
    .await;
    let _ = core.stop().await;
}

/// What such a session surfaces is recorded as a durable fanout in the hold
/// that staged it and sent by its own drive task — never on the engine's own
/// client, which holds no relay of the circle's under any other name.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_claimed_behind_its_start_records_what_it_stages_and_drives_it() {
    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let scripted = Scripted::new();
    scripted.transport.park();
    let core = scripted
        .session(admin, &fx.group, &url, Claim::Foreground)
        .await;

    let leave = feed_leave_to(core.processor(), &fx, 1, 2).await;
    // Bounded: a session that recorded nothing never parks a call, and a
    // wait with no end would hang where it should fail.
    tokio::time::timeout(Duration::from_secs(10), scripted.transport.parked())
        .await
        .expect("a session in the foreground sent nothing through its own drive");
    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the eviction has exactly one record"));
    assert_eq!(record.mls, FanoutMls::Pending);

    scripted.transport.answer(&url, [Answer::Accepted]);
    scripted.transport.unpark();
    assert!(
        held(|| async { records_of(admin, &fx.group).await.is_empty() }).await,
        "the session's own drive did not send what it recorded",
    );
    let calls = scripted.transport.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].event_id, record.event_id);
    let eviction = Event::from_json(&calls[0].payload).expect("a signed event");
    assert_the_eviction_removed(
        admin,
        &fx.members[2],
        &fx.members[1],
        &fx.group,
        &leave,
        &eviction,
    )
    .await;
    let _ = core.stop().await;
}

/// A session started by a caller that claims nothing is only started, and
/// no number of health ticks that claim nothing makes it more: a record
/// stored and never sent is sent by none of them, nor by a drive asked of
/// it directly — a first send is the foreground's, and no relay is taken
/// for one. The first tick that carries the claim puts the session in the
/// foreground, and its drive sends the record.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_nobody_claimed_makes_no_first_send_however_many_ticks_arrive() {
    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let earlier = Plane::over(&admin.circle);
    earlier.processor.for_test().set_background_burst(false);
    feed_leave(&earlier, &fx, 1, 2).await;
    drop(earlier);
    let before = standing_of(admin, &fx.group).await;
    assert_eq!(before.len(), 1, "premise: one stored record, never sent");

    let scripted = Scripted::new();
    scripted.transport.answer(&url, [Answer::Accepted]);
    let core = scripted
        .session(admin, &fx.group, &url, Claim::Nothing)
        .await;
    assert_eq!(core.processor().lifecycle(), Lifecycle::Launched);
    for _ in 0..5 {
        let tick = core
            .maintain_subscription_health(Claim::Nothing)
            .await
            .expect("the tick answers");
        assert_eq!(tick.action, HealthAction::Healthy);
        assert_eq!(
            core.processor().lifecycle(),
            Lifecycle::Launched,
            "a tick that claimed nothing put a started session in the foreground",
        );
        core.processor().for_test().drive_due().await;
    }
    assert_eq!(
        (
            scripted.counting.takes.load(Ordering::SeqCst),
            scripted.transport.call_count(),
            scripted.outbox.handed().len(),
        ),
        (0, 0, 0),
        "a session nobody claimed took a relay, or published",
    );
    assert_eq!(standing_of(admin, &fx.group).await, before);
    assert!(staged_ref(admin, &fx.group).await.is_some());

    core.maintain_subscription_health(Claim::Foreground)
        .await
        .expect("the tick answers");
    assert_eq!(core.processor().lifecycle(), Lifecycle::Foreground);
    assert!(
        held(|| async { records_of(admin, &fx.group).await.is_empty() }).await,
        "control: the record was the claimed session's to send all along",
    );
    assert_eq!(scripted.transport.calls().len(), 1);
    let _ = core.stop().await;
}

/// What a launch costs when nothing is due, whatever it claims: the start
/// asks for one drive, that drive runs, and it takes no relay — so nothing
/// is called and nothing is dialled — and publishes nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_launch_with_nothing_due_runs_one_drive_that_takes_no_relay() {
    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();

    let unclaimed = Scripted::new();
    let core = unclaimed
        .session(admin, &fx.group, &url, Claim::Nothing)
        .await;
    assert!(
        unclaimed.a_drive_ran(&core, 0).await,
        "a start asked for no drive of what is stored",
    );
    core.processor().for_test().drive_due().await;
    assert_eq!(
        (
            unclaimed.counting.takes.load(Ordering::SeqCst),
            unclaimed.transport.call_count(),
            unclaimed.outbox.handed().len(),
        ),
        (0, 0, 0),
        "a launch that claimed nothing took a relay or published, with nothing due",
    );
    let _ = core.stop().await;

    let scripted = Scripted::new();
    let core = scripted
        .session(admin, &fx.group, &url, Claim::Foreground)
        .await;
    assert!(
        scripted.a_drive_ran(&core, 0).await,
        "a claim made behind a start asked for no drive",
    );
    assert_eq!(
        (
            scripted.counting.takes.load(Ordering::SeqCst),
            scripted.transport.call_count(),
            scripted.outbox.handed().len(),
            records_of(admin, &fx.group).await.len(),
        ),
        (0, 0, 0, 0),
        "a drive with nothing due took a relay, published, or left a record",
    );
    assert_eq!(
        core.processor().drive_retry_after_ms(),
        None,
        "a drive with nothing due left a time to wake for",
    );
    let _ = core.stop().await;
}

/// The most a relay that answers nothing is called when every visit to the
/// app is a session of its own — started, claimed for, driven once by that
/// claim, and ended — three visits a minute for two hours and five
/// minutes. The schedule is the stored record's, so it is carried from one
/// session to the next: the calls are the relay's own schedule and nothing
/// else, exactly those one unbroken session makes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_silent_relay_is_called_on_its_schedule_however_often_the_app_is_opened() {
    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let transport = Arc::new(ScriptedFanout::default());
    let counting = Arc::new(Counting {
        inner: Arc::clone(&transport),
        takes: AtomicU64::new(0),
    });
    let clock = Clock::at(0);
    // One visit's session, as a start and the claim behind it leave it.
    let visit = || {
        let processor = EngineProcessor::with_driver(
            Arc::clone(&admin.circle),
            EventBus::new(),
            LiveDriver {
                fanout: Arc::clone(&counting) as Arc<dyn FanoutSend>,
                publisher: Recording::acking(true),
                clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
            },
        );
        processor.for_test().note_launched();
        assert!(processor.for_test().prove_foreground());
        processor
    };
    let first = visit();
    feed_leave_to(&first, &fx, 1, 2).await;
    first.for_test().leave_foreground();
    drop(first);
    transport.answer(RELAY, [Answer::Silent]);

    let mut called_at = Vec::new();
    for minute in 0..125_u64 {
        clock.set(minute * 60 * SECOND_MS);
        for _ in 0..3 {
            let session = visit();
            // The one drive a foreground start asks for.
            session.for_test().drive_due().await;
            // The visit ends — a pause, or a stop — and nothing follows it.
            session.for_test().leave_foreground();
            session.for_test().drive_due().await;
        }
        for _ in transport.calls() {
            called_at.push(minute);
        }
    }

    assert_eq!(
        called_at,
        [0, 1, 2, 4, 8, 16, 32, 64, 124],
        "the minutes a silent relay was called in, over 375 visits",
    );
    assert_eq!(
        counting.takes.load(Ordering::SeqCst),
        9,
        "a relay was taken for a visit in which it was not due",
    );
}

/// The same, with real sessions: each visit is a session started on a
/// foreground claim over the same stores, driven once in that foreground,
/// waited for until no drive has a call out, and stopped. Two visits in one
/// minute make one call, and a visit in a minute the relay is not due makes
/// none.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_sessions_started_one_after_another_keep_a_stored_records_schedule() {
    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let earlier = Plane::over(&admin.circle);
    earlier.processor.for_test().set_background_burst(false);
    feed_leave(&earlier, &fx, 1, 2).await;
    drop(earlier);

    let scripted = Scripted::new();
    scripted.transport.answer(&url, [Answer::Silent]);
    let mut called_at = Vec::new();
    for minute in [0_u64, 0, 1, 1, 2, 3, 4, 5] {
        scripted.clock.set(minute * 60 * SECOND_MS);
        let core = scripted
            .session(admin, &fx.group, &url, Claim::Foreground)
            .await;
        // Inline: the drive the claim asks for races the one the start
        // asked for, which only finishes and so begins no first call.
        core.processor().for_test().drive_due().await;
        assert!(
            held(|| async { core.in_flight_publishes() == 0 }).await,
            "a visit's drive never ended",
        );
        let _ = core.stop().await;
        for _ in scripted.transport.calls() {
            called_at.push(minute);
        }
    }
    assert_eq!(
        called_at,
        [0, 1, 2, 4],
        "the minutes a silent relay was called in, over eight sessions",
    );
    assert_eq!(scripted.counting.takes.load(Ordering::SeqCst), 4);
}

/// A full drive of the live plane in its claimed foreground that could not
/// list the stored rows — an error no circle can be named for — ends no
/// circle's wait for a foreground: any of them may own a row the drive never
/// saw. The next drive that lists them ends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_drive_that_could_not_list_its_rows_ends_no_circles_wait_for_a_foreground() {
    use haven_core::nostr::mls::storage::set_fanout_read_fault_for_test;

    let fx = setup_circle(2, &[RELAY]).await;
    let admin = &fx.members[0];
    let group = &fx.group;
    haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
    rusqlite::Connection::open(
        admin
            .dir
            .path()
            .join(haven_core::circle::CIRCLES_DB_FILENAME),
    )
    .expect("the circle store opens")
    .execute(
        "INSERT INTO commit_notes (mls_group_id, untold) VALUES (?1, ?2)
         ON CONFLICT(mls_group_id) DO UPDATE SET untold = untold | ?2",
        rusqlite::params![group.as_slice(), ChangeNote::AwaitsForeground.bit()],
    )
    .expect("a change of relays finished away is planted");
    let awaits = || {
        admin
            .session()
            .peek_change_notes(group)
            .contains(&ChangeNote::AwaitsForeground)
    };
    let plane = Plane::over(&admin.circle);
    plane.processor.for_test().set_background_burst(false);
    let db = StorageConfig::new(admin.dir.path()).database_path();
    let key = StorageConfig::test_sqlcipher_key().expect("test key");

    set_fanout_read_fault_for_test(&db, &key, true).expect("arm");
    plane.processor.for_test().drive_due().await;
    set_fanout_read_fault_for_test(&db, &key, false).expect("disarm");
    assert!(
        awaits(),
        "a full drive that could not list its rows ended a circle's wait for a foreground",
    );
    plane.processor.for_test().drive_due().await;
    assert!(
        !awaits(),
        "premise: a full drive of the claimed foreground ends the wait"
    );
}

/// A stop whose lifecycle lock a wedged holder keeps tears down beside it,
/// and what that leaves is safe though the holder lives on: the call the
/// session's drive had under way is given up and kept as possibly exposed,
/// never confirmed; the stop answers `Drained`, which says every task of the
/// session joined and nothing about the holder; a new session over the same
/// circle starts; and while the old core lives it keeps the circle's manager,
/// so a second MLS session over the same database is refused (Security Rule
/// 14).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bounded_stop_beside_a_wedged_holder_leaves_no_second_session_and_no_confirm() {
    use haven_core::nostr::mls::storage::LiveSessionGuard;
    use haven_core::relay::live_sync::StopOutcome;

    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let scripted = Scripted::new();
    scripted.transport.park();
    let old = scripted
        .session(admin, &fx.group, &url, Claim::Foreground)
        .await;
    feed_leave_to(old.processor(), &fx, 1, 2).await;
    tokio::time::timeout(Duration::from_secs(10), scripted.transport.parked())
        .await
        .expect("premise: the session's drive has its call under way");
    let evicting = staged_ref(admin, &fx.group).await.expect("staged");

    let wedged = old.hold_lifecycle_for_test().await;
    let stopped = tokio::time::timeout(
        Duration::from_secs(30),
        old.stop_within_for_test(Duration::from_millis(200)),
    )
    .await
    .expect("a stop waited on a holder that would not give its lock up");
    assert_eq!(stopped, StopOutcome::Drained, "premise: every task joined");
    let [record] = <[FanoutProbe; 1]>::try_from(records_of(admin, &fx.group).await)
        .unwrap_or_else(|_| panic!("the record is still there"));
    assert!(
        record.statuses == [FanoutTargetStatus::PossiblyExposed]
            && record.attempts == [1]
            && staged_ref(admin, &fx.group).await == Some(evicting),
        "the call under way at the stop was not given up and kept, or its commit moved",
    );
    scripted.transport.answer(&url, [Answer::Accepted]);
    scripted.transport.unpark();
    old.processor().for_test().drive_due().await;
    assert!(
        staged_ref(admin, &fx.group).await == Some(evicting)
            && scripted.transport.calls().len() == 1,
        "the stopped session's holder called a relay or confirmed a commit",
    );

    let next = Scripted::new();
    let new = next.session(admin, &fx.group, &url, Claim::Nothing).await;
    assert_eq!(
        new.processor().lifecycle(),
        Lifecycle::Launched,
        "a new session did not start beside the wedged holder",
    );
    let _ = new.stop().await;
    drop(new);

    let db = StorageConfig::new(admin.dir.path()).database_path();
    assert!(
        LiveSessionGuard::acquire(&db).is_err(),
        "a second MLS session opened over a database a live manager holds",
    );
    let held_with_old = Arc::strong_count(&admin.circle);
    drop(wedged);
    drop(old);
    assert!(
        Arc::strong_count(&admin.circle) < held_with_old,
        "the stopped core did not hold the circle's manager while it lived",
    );
}

/// A burst whose opener measured its OS budget begins no relay call that
/// budget cannot finish — a call the OS cut would be stored possibly exposed
/// for good: with less than a row's budget left the due relay is not called
/// and the record stands as it was. The measured end goes with its burst: the
/// foreground after it calls the relay and confirms what it acknowledges.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bursts_drive_begins_no_call_its_measured_budget_cannot_finish() {
    use haven_core::relay::fanout::ROW_BUDGET_MS;

    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let transport = Arc::new(ScriptedFanout::default());
    let clock = Arc::new(Ticking(AtomicU64::new(Clock::ORIGIN)));
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true),
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    processor.for_test().set_background_burst(false);
    feed_leave_to(&processor, &fx, 1, 2).await;
    transport.answer(RELAY, [Answer::Silent]);
    processor.for_test().drive_due().await;
    assert_eq!(transport.calls().len(), 1, "premise: sent once, unanswered");
    let before = records_of(admin, &fx.group).await;

    clock
        .0
        .store(Clock::ORIGIN + 3_600 * SECOND_MS, Ordering::SeqCst);
    processor.for_test().set_background_burst(true);
    transport.answer(RELAY, [Answer::Accepted]);
    processor
        .for_test()
        .set_burst_budget(Some(ROW_BUDGET_MS - 1));
    processor.for_test().drive_due().await;
    let after = records_of(admin, &fx.group).await;
    assert!(
        transport.calls().is_empty()
            && staged_ref(admin, &fx.group).await.is_some()
            && after.len() == 1
            && after[0].attempts == before[0].attempts,
        "a burst began a relay call its measured budget could not finish",
    );

    // The burst's measured end is that burst's alone: the foreground that
    // follows it drives on its own budget.
    processor.for_test().set_background_burst(false);
    processor.for_test().drive_due().await;
    assert!(
        transport.calls().len() == 1
            && staged_ref(admin, &fx.group).await.is_none()
            && !roster(admin, &fx.group)
                .await
                .contains(&fx.members[1].pubkey_hex()),
        "a burst's measured end held the foreground that followed it, or the due relay's \
         acknowledgement was not confirmed",
    );
}

/// A drive of the live plane's own whose every relay refuses the commit for
/// its timestamp puts the clock verdict on the bus: the plane has no caller
/// to answer, and the clock check reads the bus.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_drive_refused_for_the_clock_puts_the_verdict_on_the_bus() {
    use haven_core::relay::clock_skew::DeviceClockComplaint;
    use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};
    let relay = ScriptedRelay::start();
    relay.on_publish(|_| {
        Verdict::Refuse("invalid: event creation date is in the future".to_string())
    });
    let fx = setup_circle(3, &[relay.url()]).await;
    let admin = fx.admin();
    let relay_mgr = RelayManager::new();
    let bus = EventBus::new();
    let mut heard = bus.subscribe();
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        bus,
        LiveDriver {
            fanout: Arc::new(relay_mgr.fanout_transport()) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true),
            clock: Arc::new(Ticking(AtomicU64::new(Clock::ORIGIN))) as Arc<dyn FanoutClock>,
        },
    );
    processor.for_test().set_background_burst(false);
    feed_leave_to(&processor, &fx, 1, 2).await;
    processor.for_test().drive_due().await;
    let mut verdict = None;
    while let Ok(event) = heard.try_recv() {
        if let LiveSyncEvent::ClockRejected { complaint } = event {
            verdict = Some(complaint);
        }
    }
    assert!(
        relay.offers() > 0,
        "premise: the commit was offered and refused"
    );
    assert_eq!(
        verdict,
        Some(DeviceClockComplaint::Ahead),
        "a live drive's clock refusal did not reach the bus",
    );
}

/// A burst's measured end is kept on the monotonic clock as well: a wall
/// clock set back during the burst — an NTP step on wake — gives its drive
/// no more room than the budget it was opened with. With less than a row's
/// budget measured, the due relay is not called though the clock now reads
/// an hour earlier; measured with room for a row, it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_bursts_measured_end_is_not_stretched_by_a_clock_set_back() {
    use haven_core::relay::fanout::{RESUME_BUDGET_MS, ROW_BUDGET_MS};

    let fx = setup_circle(3, &[RELAY]).await;
    let admin = fx.admin();
    let transport = Arc::new(ScriptedFanout::default());
    let clock = Arc::new(Ticking(AtomicU64::new(Clock::ORIGIN)));
    let processor = EngineProcessor::with_driver(
        Arc::clone(&admin.circle),
        EventBus::new(),
        LiveDriver {
            fanout: Arc::clone(&transport) as Arc<dyn FanoutSend>,
            publisher: Recording::acking(true),
            clock: Arc::clone(&clock) as Arc<dyn FanoutClock>,
        },
    );
    processor.for_test().set_background_burst(false);
    feed_leave_to(&processor, &fx, 1, 2).await;
    transport.answer(RELAY, [Answer::Silent]);
    processor.for_test().drive_due().await;
    assert_eq!(transport.calls().len(), 1, "premise: sent once, unanswered");

    processor.for_test().set_background_burst(true);
    transport.answer(RELAY, [Answer::Accepted]);
    for (budget_ms, calls) in [(ROW_BUDGET_MS - 1, 0), (RESUME_BUDGET_MS, 1)] {
        clock
            .0
            .store(Clock::ORIGIN + 7_200 * SECOND_MS, Ordering::SeqCst);
        processor.for_test().set_burst_budget(Some(budget_ms));
        clock
            .0
            .store(Clock::ORIGIN + 3_600 * SECOND_MS, Ordering::SeqCst);
        processor.for_test().drive_due().await;
        assert_eq!(
            transport.calls().len(),
            calls,
            "a burst measured at {budget_ms} ms called a relay its budget could not finish \
             once the clock was set back, or did not call one it could",
        );
    }
}

/// The session's burst open that carries its caller's measured OS budget
/// hands it to the burst's own drive: opened with less than a row's budget,
/// the drive it asks for calls no relay; opened again with room for a row,
/// the due relay is called and the commit it acknowledges confirmed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_opened_within_a_measured_budget_hands_it_to_its_drive() {
    use haven_core::relay::fanout::{RESUME_BUDGET_MS, ROW_BUDGET_MS};

    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let scripted = Scripted::new();
    scripted.transport.answer(&url, [Answer::Silent]);
    let core = scripted
        .session(admin, &fx.group, &url, Claim::Foreground)
        .await;
    feed_leave_to(core.processor(), &fx, 1, 2).await;
    assert!(
        held(|| async {
            records_of(admin, &fx.group)
                .await
                .first()
                .is_some_and(|record| record.attempts == [1])
        })
        .await,
        "premise: the eviction was sent once, unanswered",
    );
    assert!(
        held(|| async { core.processor().in_flight_publishes() == 0 }).await,
        "premise: the foreground's drive has ended",
    );
    let _ = scripted.transport.calls();
    core.pause_subscriptions()
        .await
        .expect("the session pauses");
    scripted.clock.set(3_600 * SECOND_MS);
    scripted.transport.answer(&url, [Answer::Accepted]);

    core.open_background_burst_within(ROW_BUDGET_MS - 1)
        .await
        .expect("the burst opens");
    // A pass that left a due row for want of room says so: come back at once.
    assert!(
        held(|| async {
            core.processor().drive_retry_after_ms() == Some(0)
                && core.processor().in_flight_publishes() == 0
        })
        .await,
        "premise: the burst drove and left the row for want of room",
    );
    assert!(
        scripted.transport.calls().is_empty() && staged_ref(admin, &fx.group).await.is_some(),
        "a burst opened within less than a row's budget called a relay",
    );
    core.pause_subscriptions()
        .await
        .expect("the session pauses");

    core.open_background_burst_within(RESUME_BUDGET_MS)
        .await
        .expect("the burst opens");
    assert!(
        held(|| async { staged_ref(admin, &fx.group).await.is_none() }).await
            && scripted.transport.calls().len() == 1,
        "a burst opened with room for a row did not call the due relay, or did not confirm \
         the commit it acknowledged",
    );
    let _ = core.stop().await;
}

/// A session started into a burst with its caller's measured OS budget hands
/// that budget to its drive: started with less than a row's budget, it calls
/// no relay for a record sent before and due; started with room for a row,
/// it calls the due relay and confirms the commit it acknowledges.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_started_into_a_burst_within_a_measured_budget_hands_it_to_its_drive() {
    use haven_core::relay::fanout::{RESUME_BUDGET_MS, ROW_BUDGET_MS};

    let (fx, _relay, url) = a_circle_on_a_local_relay().await;
    let admin = fx.admin();
    let earlier = Plane::over(&admin.circle);
    earlier.processor.for_test().set_background_burst(false);
    feed_leave(&earlier, &fx, 1, 2).await;
    earlier.transport.answer(&url, [Answer::Silent]);
    earlier.processor.for_test().drive_due().await;
    assert_eq!(
        earlier.transport.calls().len(),
        1,
        "premise: sent once, unanswered"
    );
    drop(earlier);

    let spec = CircleSpec {
        group_id_hex: hex::encode(ngid(admin, &fx.group).await),
        relays: vec![url.clone()],
    };
    for (budget_ms, calls) in [(ROW_BUDGET_MS - 1, 0), (RESUME_BUDGET_MS, 1)] {
        let scripted = Scripted::new();
        scripted.clock.set(3_600 * SECOND_MS);
        scripted.transport.answer(&url, [Answer::Accepted]);
        let core = LiveSyncCore::new_local_with_driver_for_test(
            Arc::clone(&admin.circle),
            admin.keys.public_key(),
            scripted.driver(),
        );
        core.start_into_burst(std::slice::from_ref(&spec), &[], Some(budget_ms))
            .await
            .expect("the session starts into a burst");
        // Each pass ends one of two ways: the commit confirmed, or the row
        // left for want of room, which it says by asking to come back at once.
        assert!(
            held(|| async {
                core.processor().in_flight_publishes() == 0
                    && (staged_ref(admin, &fx.group).await.is_none()
                        || core.processor().drive_retry_after_ms() == Some(0))
            })
            .await,
            "premise: the burst drove",
        );
        assert_eq!(
            (
                scripted.transport.calls().len(),
                staged_ref(admin, &fx.group).await.is_none()
            ),
            (calls, calls == 1),
            "a start into a burst with {budget_ms} ms called a relay it could not finish, or \
             did not call one it could",
        );
        let _ = core.stop().await;
    }
}
