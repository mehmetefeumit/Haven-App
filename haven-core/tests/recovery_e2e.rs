//! What a circle that is not sharing tells the user (W14): MDK's durable
//! `unrecoverable` read on every circle read and after every restart, the
//! epoch-stall detector that walks a circle's own history when it fell
//! behind and names it `Stalled` only on relays' confirmed verdicts, and the
//! one standing recovery read, worst cause first.
//!
//! Real MDK engines over their own stores; relays are in-process
//! (`MockRelay`) or scripted, and nothing real is dialled. The detector's
//! clock is the session's injectable one (`set_legacy_clock_for_test`); the
//! only real time paid is the engine's own convergence window where a commit
//! applies (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK).

mod helpers;

use haven_core::circle::{CircleEngineState, SkipReason};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::relay::catchup::run_catchup_in_foreground;
use haven_core::relay::fanout::scripted::{Answer, ScriptedFanout};
use haven_core::relay::fanout::{DriveMode, RecoveryCause, RepairOutcome};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use helpers::drive::{through, ManualClock, Recorder};
use helpers::stranded::split;
use helpers::{setup_circle, CircleMember};
use nostr::{Event, EventBuilder, JsonUtil as _, Keys, Kind, Tag, TagKind, Timestamp};
use nostr_relay_builder::MockRelay;

const RELAY: &str = "wss://one.recovery-canary8c3d.example.com";

const HOUR_MS: u64 = 60 * 60 * 1_000;

/// The session clock's origin for the detector's waits.
const T0: u64 = 1_700_000_000_000;

async fn engine_state(member: &CircleMember, group: &GroupId) -> CircleEngineState {
    member
        .circle
        .get_circle(group)
        .await
        .expect("read")
        .expect("the circle")
        .engine_state
}

async fn recovery(
    member: &CircleMember,
    group: &GroupId,
    foreground: bool,
) -> Option<RecoveryCause> {
    member
        .circle
        .circle_recovery_for_test(group, foreground)
        .await
        .expect("the recovery read")
}

/// A day and an hour past the device's real clock, in Unix seconds: past
/// every repair gate a fresh circle stamps in real time.
fn past_every_repair_gate() -> u64 {
    u64::try_from(chrono::Utc::now().timestamp()).expect("clock") + 25 * 60 * 60
}

/// A circle MDK halted reads `Unrecoverable` on every read — the list, the
/// circle, the recovery read in and out of the foreground — with no bus event
/// needed, and still after another restart. The repair calls it terminal, and
/// no member is listed for it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unrecoverable_circle_reads_unrecoverable_on_every_read_and_after_a_restart() {
    let fx = setup_circle(2, &[RELAY]).await;
    let (_admin, mut others, group) = split(fx);
    let mut member = others.remove(0).halted(&group);
    for restart in [false, true] {
        if restart {
            member = member.reopen();
        }
        let listed = member.circle.get_circles().await.expect("the list");
        let row = listed
            .iter()
            .find(|circle| circle.circle.mls_group_id == group)
            .expect("the circle is listed");
        assert_eq!(row.engine_state, CircleEngineState::Unrecoverable);
        assert!(row.members.is_empty(), "a halted circle lists no members");
        assert_eq!(
            engine_state(&member, &group).await,
            CircleEngineState::Unrecoverable
        );
        for foreground in [true, false] {
            for read in 0..2 {
                assert_eq!(
                    recovery(&member, &group, foreground).await,
                    Some(RecoveryCause::Unrecoverable),
                    "read {read} (foreground: {foreground}, restart: {restart})"
                );
            }
        }
        assert!(matches!(
            member
                .circle
                .repair_rotation_for_test(&group, past_every_repair_gate())
                .await
                .expect("the repair's answer")
                .0,
            RepairOutcome::Skipped(SkipReason::EpochUnrecoverable)
        ));
    }
}

/// A circle that failed to load reads `Quarantined` — its recovery too — and
/// never fails the list the other circles are read in (AM-R3-5).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_quarantined_circle_reads_quarantined_and_never_fails_the_list() {
    use haven_core::nostr::mls::storage::{
        delete_openmls_group_state_for_test, openmls_group_keys_for_test,
    };
    let founder = CircleMember::new();
    let member = CircleMember::new();
    let kept = helpers::found_circle(&founder, &[&member], &[RELAY]).await;
    let db = haven_core::nostr::mls::StorageConfig::new(member.dir.path()).database_path();
    let key = haven_core::nostr::mls::StorageConfig::test_sqlcipher_key().expect("test key");
    let CircleMember { circle, keys, dir } = member;
    drop(std::sync::Arc::try_unwrap(circle).unwrap_or_else(|_| panic!("shared")));
    let before = openmls_group_keys_for_test(&db, &key).expect("the group keys");
    let member = CircleMember {
        circle: std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys).expect("reopen"),
        ),
        keys,
        dir,
    };
    let lost = helpers::found_circle(&founder, &[&member], &[RELAY]).await;
    let CircleMember { circle, keys, dir } = member;
    drop(std::sync::Arc::try_unwrap(circle).unwrap_or_else(|_| panic!("shared")));
    let after = openmls_group_keys_for_test(&db, &key).expect("the group keys");
    let quarantined = after
        .iter()
        .find(|group| !before.contains(group))
        .expect("the second circle's state");
    delete_openmls_group_state_for_test(&db, &key, quarantined).expect("the state is lost");
    let member = CircleMember {
        circle: std::sync::Arc::new(
            haven_core::circle::CircleManager::new_unencrypted(dir.path(), &keys).expect("reopen"),
        ),
        keys,
        dir,
    };

    let listed = member
        .circle
        .get_circles()
        .await
        .expect("one bad circle fails no list");
    let state = |group: &GroupId| {
        listed
            .iter()
            .find(|circle| &circle.circle.mls_group_id == group)
            .map(|circle| circle.engine_state)
    };
    assert_eq!(state(&lost), Some(CircleEngineState::Quarantined));
    assert_eq!(state(&kept), Some(CircleEngineState::Live));
    assert_eq!(
        recovery(&member, &lost, true).await,
        Some(RecoveryCause::Quarantined),
        "a quarantined circle's recovery reads its quarantine, never an error"
    );
    assert_eq!(recovery(&member, &kept, true).await, None);
}

/// Each real source of a held circle reaches the recovery read as its own
/// cause: a disband, a leave, a routing collision, a change awaiting its
/// relays — and nothing at all for a healthy circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn circle_recovery_reads_each_real_cause() {
    // Healthy.
    let fx = setup_circle(2, &[RELAY]).await;
    assert_eq!(recovery(fx.admin(), &fx.group, true).await, None);
    assert_eq!(recovery(&fx.members[1], &fx.group, false).await, None);

    // Awaiting relays: the admin's removal sent and never acknowledged.
    let fx = setup_circle(3, &[RELAY]).await;
    let transport = ScriptedFanout::default();
    transport.answer(RELAY, [Answer::Silent]);
    let _ = through(
        &transport,
        &Recorder::acking(true),
        &ManualClock::at(0),
        &DriveMode::Full,
    )
    .remove_members(&fx.admin().circle, &fx.group, &[fx.members[2].pubkey_hex()])
    .await
    .expect("the removal is staged and sent");
    assert_eq!(
        recovery(fx.admin(), &fx.group, true).await,
        Some(RecoveryCause::AwaitingRelays)
    );

    // Leaving.
    let fx = setup_circle(2, &[RELAY]).await;
    let _ = fx.members[1]
        .circle
        .propose_leave(&fx.group)
        .await
        .expect("the member leaves");
    assert_eq!(
        recovery(&fx.members[1], &fx.group, true).await,
        Some(RecoveryCause::Leaving)
    );

    // A routing collision.
    let fx = setup_circle(2, &[RELAY]).await;
    fx.members[1]
        .session()
        .note_routing_collision_for_test(&fx.group)
        .expect("the collision is noted");
    assert_eq!(
        recovery(&fx.members[1], &fx.group, true).await,
        Some(RecoveryCause::RoutingCollision)
    );

    // Disbanded.
    let fx = setup_circle(2, &[RELAY]).await;
    let commit = helpers::drive::disband(fx.admin(), &fx.group).await;
    helpers::drive::take_in_disband(&fx.members[1], &fx.group, &commit).await;
    assert_eq!(
        recovery(&fx.members[1], &fx.group, true).await,
        Some(RecoveryCause::Disbanded)
    );
}

/// A kind-445 for the circle routed by `routing` that nobody can decrypt:
/// its public `h` tag on random bytes, signed by a throwaway key, at
/// `created_at_secs`.
fn undecryptable(routing: &[u8; 32], created_at_secs: u64) -> Event {
    use rand::RngCore as _;
    let mut bytes = [0u8; 96];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    EventBuilder::new(
        Kind::Custom(445),
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes),
    )
    .tag(Tag::custom(TagKind::custom("h"), [hex::encode(routing)]))
    .custom_created_at(Timestamp::from(created_at_secs))
    .sign_with_keys(&Keys::generate())
    .expect("a forged envelope")
}

/// `observed` re-signed under a fresh key at `created_at_secs`: a relay
/// serving an event late, under an old timestamp.
fn backdate(observed: &Event, created_at_secs: u64) -> Event {
    EventBuilder::new(observed.kind, observed.content.clone())
        .tags(observed.tags.iter().cloned().collect::<Vec<Tag>>())
        .custom_created_at(Timestamp::from(created_at_secs))
        .sign_with_keys(&Keys::generate())
        .expect("re-sign")
}

/// `member` takes `event` in as a claimed foreground's receive does.
async fn take_in(member: &CircleMember, event: &Event) {
    let _ = member
        .session()
        .process_event_staging_for_test(event, 0, &DriveMode::Full)
        .await
        .expect("the ingest runs");
}

fn now_secs() -> u64 {
    u64::try_from(chrono::Utc::now().timestamp()).expect("clock")
}

async fn routing(member: &CircleMember, group: &GroupId) -> [u8; 32] {
    helpers::drive::ngid(member, group).await
}

/// A circle of three on an in-process relay: B misses the admin's removal of
/// C (`missed`, never handed to B).
struct Behind {
    _relay: MockRelay,
    url: String,
    relays: RelayManager,
    fx: helpers::CircleFixture,
    missed: Event,
}

/// `fx`'s member `joiner` makes its post-join self-update through a full
/// resume, every relay at `url` accepting, and every other member takes it
/// in. MDK's windows are served on the joiner's session clock, put a day
/// ahead for the drive and given back after it.
async fn settle_post_join_of(fx: &helpers::CircleFixture, joiner: usize, url: &str) {
    let member = &fx.members[joiner];
    let transport = ScriptedFanout::default();
    transport.answer(url, [Answer::Accepted]);
    let ahead = u64::try_from(chrono::Utc::now().timestamp_millis()).expect("clock") + 24 * HOUR_MS;
    member.session().set_legacy_clock_for_test(ahead);
    member.session().mark_caught_up_for_test(&fx.group);
    member
        .session()
        .set_legacy_clock_for_test(ahead + 2 * 60 * 1_000);
    let _ = through(
        &transport,
        &Recorder::acking(true),
        &ManualClock::at(0),
        &DriveMode::Full,
    )
    .resume(&member.circle)
    .await;
    member.session().set_legacy_clock_for_test(0);
    let calls = transport.calls();
    let commit = Event::from_json(&calls.last().expect("the self-update was sent").payload)
        .expect("the commit");
    for (other, peer) in fx.members.iter().enumerate() {
        if other != joiner {
            peer.circle
                .ingest_for_test(&commit)
                .await
                .expect("taken in");
        }
    }
}

async fn behind() -> Behind {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let fx = setup_circle(3, &[url.as_str()]).await;
    // Each joiner's post-join self-update made first, and taken in by the
    // others, so no later drive makes one from the epoch B is left at.
    for joiner in 1..3 {
        settle_post_join_of(&fx, joiner, &url).await;
    }
    let missed = fx
        .admin()
        .circle
        .remove_members_for_test(&fx.group, &[fx.members[2].pubkey_hex()])
        .await
        .expect("the admin removes C");
    Behind {
        _relay: relay,
        url,
        relays: RelayManager::new(),
        fx,
        missed,
    }
}

/// B, behind by one commit, is sent eight fixes it cannot open: the detector
/// arms, the circle owes a walk of its own history, and the next foreground
/// sweep walks it down to the circle's start — where the commit, served late
/// under a timestamp three days old that no forward sweep reaches, is found.
/// B applies it, reads the next fix, and nothing holds the circle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_circle_that_missed_a_commit_backfills_its_history_and_catches_up() {
    let behind = behind().await;
    let (fx, b) = (&behind.fx, &behind.fx.members[1]);
    let old = now_secs() - 3 * 24 * 60 * 60;
    let published = behind
        .relays
        .publish_event(
            &backdate(&behind.missed, old),
            std::slice::from_ref(&behind.url),
        )
        .await
        .expect("the commit reaches the relay, late");
    assert!(
        published.is_success(),
        "premise: the relay holds the late commit"
    );
    let before = b.session().epoch(&fx.group).await.expect("epoch");
    for latitude in 0..8 {
        let (fix, _, _) = fx
            .admin()
            .circle
            .seal_location_for_test(&fx.group, &LocationMessage::new(f64::from(latitude), 1.0))
            .await
            .expect("the admin seals at the new epoch");
        take_in(b, &fix).await;
    }
    assert_eq!(
        b.session().stall_arms_for_test(),
        1,
        "eight unreadable fixes arm one walk"
    );
    assert!(
        b.session().owes_refetch(&fx.group),
        "the arm owes the circle a walk of its history"
    );

    let _ = run_catchup_in_foreground(&b.circle, &behind.relays, 30).await;
    assert!(
        !b.session().owes_refetch(&fx.group),
        "the walk ran to the circle's start and settled the range"
    );
    // The commit the walk brought back applies once the engine's own
    // convergence window, which it announces, has passed.
    let session = b.session();
    let _ = session.advance_for_receive(&fx.group).await;
    while let Some(after) = session.receive_retick_after(&fx.group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(&fx.group).await;
    }
    assert!(
        b.session().epoch(&fx.group).await.expect("epoch") > before,
        "the walk brought back the commit B missed"
    );
    let (fix, _, _) = fx
        .admin()
        .circle
        .seal_location_for_test(&fx.group, &LocationMessage::new(9.0, 1.0))
        .await
        .expect("the admin seals again");
    let read = b.circle.ingest_for_test(&fix).await.expect("ingest");
    assert!(
        read.iter()
            .any(|result| matches!(result, LocationMessageResult::Location { .. })),
        "B reads the circle again"
    );
    assert!(!b.session().stalled_for_test(&fx.group));
    assert_eq!(recovery(b, &fx.group, true).await, None);
}

/// On the live plane an arm asks for one refetch — once, however many
/// unreadable fixes the plane takes in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stall_arm_on_the_live_plane_asks_for_one_refetch() {
    use haven_core::relay::live_sync::{
        EngineProcessor, EventBus, LiveSyncEvent, SyncStatusReason,
    };
    let behind = behind().await;
    let (fx, b) = (&behind.fx, &behind.fx.members[1]);
    let bus = EventBus::new();
    let mut rx = bus.subscribe();
    let processor = EngineProcessor::new(std::sync::Arc::clone(&b.circle), bus);
    assert!(processor.for_test().prove_foreground());
    let id = routing(b, &fx.group).await;
    for latitude in 0..12 {
        let (fix, _, _) = fx
            .admin()
            .circle
            .seal_location_for_test(&fx.group, &LocationMessage::new(f64::from(latitude), 1.0))
            .await
            .expect("the admin seals at the new epoch");
        processor.process_group_event(&fix, &id).await;
    }
    let mut asks = 0;
    while let Ok(event) = rx.try_recv() {
        if matches!(
            event,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::RefetchOwed
            }
        ) {
            asks += 1;
        }
    }
    assert_eq!(b.session().stall_arms_for_test(), 1, "premise: one arm");
    assert_eq!(
        asks, 1,
        "one arm asks the live plane for exactly one refetch"
    );
}

/// No relay holds the commit B missed. Three walks of the circle's history,
/// an hour apart, each re-armed by the next unreadable fix and each answered
/// in full with nothing that moves B, name the circle `Stalled` — on the
/// relays' verdict, never on a count of arms. That survives a restart, and a
/// join clears it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stall_whose_history_walks_come_back_empty_three_times_is_named_stalled() {
    let behind = behind().await;
    let (fx, b) = (&behind.fx, &behind.fx.members[1]);
    let id = routing(b, &fx.group).await;
    let mut fixes = Vec::new();
    for latitude in 0..10 {
        let (fix, _, _) = fx
            .admin()
            .circle
            .seal_location_for_test(&fx.group, &LocationMessage::new(f64::from(latitude), 1.0))
            .await
            .expect("the admin seals at the new epoch");
        fixes.push(fix);
    }
    b.session().set_legacy_clock_for_test(T0);
    for fix in &fixes[..8] {
        take_in(b, fix).await;
    }
    for walk in 1..=3_u64 {
        if walk > 1 {
            // An hour on: one more unreadable envelope re-arms the paced walk.
            b.session().set_legacy_clock_for_test(T0 + walk * HOUR_MS);
            take_in(b, &undecryptable(&id, now_secs())).await;
        }
        assert!(
            !b.session().stalled_for_test(&fx.group),
            "not before walk {walk}"
        );
        let _ = run_catchup_in_foreground(&b.circle, &behind.relays, 30).await;
    }
    assert!(
        b.session().stalled_for_test(&fx.group),
        "three relay-confirmed fruitless walks name the circle stalled"
    );
    assert_eq!(
        recovery(b, &fx.group, true).await,
        Some(RecoveryCause::Stalled)
    );
    assert_eq!(b.session().stall_arms_for_test(), 3, "one arm per walk");
}

/// The stall survives a restart (its evidence row), and a join ends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stall_survives_a_restart_and_a_join_ends_it() {
    let behind = behind().await;
    let Behind {
        fx,
        relays,
        _relay,
        url,
        ..
    } = behind;
    let (admin, mut others, group) = split(fx);
    let b = others.remove(0);
    let id = routing(&b, &group).await;
    b.session().set_legacy_clock_for_test(T0);
    for latitude in 0..8 {
        let (fix, _, _) = admin
            .circle
            .seal_location_for_test(&group, &LocationMessage::new(f64::from(latitude), 1.0))
            .await
            .expect("the admin seals");
        take_in(&b, &fix).await;
    }
    for walk in 1..=3_u64 {
        if walk > 1 {
            b.session().set_legacy_clock_for_test(T0 + walk * HOUR_MS);
            take_in(&b, &undecryptable(&id, now_secs())).await;
        }
        let _ = run_catchup_in_foreground(&b.circle, &relays, 30).await;
    }
    assert!(b.session().stalled_for_test(&group), "premise: stalled");
    let b = b.reopen();
    assert!(
        b.session().stalled_for_test(&group),
        "a restart erased the relays' verdicts"
    );
    assert_eq!(
        recovery(&b, &group, true).await,
        Some(RecoveryCause::Stalled)
    );

    // The admin adds B again: the Welcome replaces B's copy.
    let package = helpers::create_key_package_event(
        b.session(),
        &b.keys,
        &["wss://member-inbox.example.com".to_string()],
    )
    .await;
    let transport = ScriptedFanout::default();
    transport.answer(&url, [Answer::Accepted]);
    let outbox = Recorder::acking(true);
    let clock = ManualClock::at(0);
    let driver = through(&transport, &outbox, &clock, &DriveMode::Full);
    let _ = driver
        .remove_members(&admin.circle, &group, &[b.pubkey_hex()])
        .await
        .expect("the admin removes B");
    let _ = driver
        .add_members(
            &admin.circle,
            &group,
            &[haven_core::circle::MemberKeyPackage {
                key_package_event: package,
                inbox_relays: vec!["wss://member-inbox.example.com".to_string()],
                nip65_relays: Vec::new(),
            }],
        )
        .await
        .expect("the admin adds B again");
    let welcome = outbox
        .handed()
        .into_iter()
        .map(|(event, _)| event)
        .find(|event| event.kind.as_u16() == 1059)
        .expect("the Welcome");
    b.circle
        .process_gift_wrapped_invitation(&b.keys, &welcome)
        .await
        .expect("the invitation is held");
    let accepted = b.circle.accept_invitation(&welcome.id).await;
    if matches!(
        accepted,
        Err(haven_core::circle::CircleError::RejoinConfirmationRequired)
    ) {
        let offers = b
            .circle
            .rejoin_offers_for_invitation(&welcome.id)
            .await
            .expect("the offer");
        b.circle
            .confirm_group_rejoin(&welcome.id, &offers[0].local_state_token)
            .await
            .expect("the consent joins");
        // The join is announced in the next batch.
        let _ = b.session().settle_receive_for_test(&group).await;
    } else {
        accepted.expect("the Welcome joins");
    }
    assert!(
        !b.session().stalled_for_test(&group),
        "a join did not end the stall"
    );
}

/// A stall that ended does not come back with a restart: B, named stalled,
/// is handed the commit it missed and moves past the epoch it stalled at;
/// reopened, it reads neither stalled nor any recovery cause.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stall_that_ended_stays_ended_after_a_restart() {
    let behind = behind().await;
    let Behind {
        fx,
        relays,
        _relay,
        missed,
        ..
    } = behind;
    let (admin, mut others, group) = split(fx);
    let b = others.remove(0);
    let id = routing(&b, &group).await;
    b.session().set_legacy_clock_for_test(T0);
    for latitude in 0..8 {
        let (fix, _, _) = admin
            .circle
            .seal_location_for_test(&group, &LocationMessage::new(f64::from(latitude), 1.0))
            .await
            .expect("the admin seals");
        take_in(&b, &fix).await;
    }
    for walk in 1..=3_u64 {
        if walk > 1 {
            b.session().set_legacy_clock_for_test(T0 + walk * HOUR_MS);
            take_in(&b, &undecryptable(&id, now_secs())).await;
        }
        let _ = run_catchup_in_foreground(&b.circle, &relays, 30).await;
    }
    assert!(b.session().stalled_for_test(&group), "premise: stalled");
    let before = b.session().epoch(&group).await.expect("epoch");

    // The commit B missed turns up, and applies once the engine's own
    // convergence window, which it announces, has passed.
    take_in(&b, &missed).await;
    let session = b.session();
    let _ = session.advance_for_receive(&group).await;
    while let Some(after) = session.receive_retick_after(&group).await {
        tokio::time::sleep(after).await;
        let _ = session.advance_for_receive(&group).await;
    }
    assert!(
        b.session().epoch(&group).await.expect("epoch") > before
            && !b.session().stalled_for_test(&group),
        "premise: B moved past the epoch it stalled at, and the stall ended"
    );

    let b = b.reopen();
    assert!(
        !b.session().stalled_for_test(&group),
        "a stall that ended came back with a restart"
    );
    assert_eq!(recovery(&b, &group, true).await, None);
}

/// An outsider floods the circle with unreadable envelopes, one a second for
/// six simulated hours, while a peer's fix arrives every 72 s and a
/// foreground sweep runs every hour, its relay answering in full: at most one
/// walk of the circle's history an hour, and the circle never reads
/// `Stalled` — the live peer's messages end each run's evidence.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_flood_of_minted_envelopes_walks_history_at_most_hourly_and_a_live_peer_keeps_the_circle_unstalled(
) {
    let _ = allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let url = relay.url().await.to_string();
    let fx = setup_circle(2, &[url.as_str()]).await;
    let (admin, b) = (fx.admin(), &fx.members[1]);
    settle_post_join_of(&fx, 1, &url).await;
    let relays = RelayManager::new();
    let id = routing(b, &fx.group).await;
    let hours = 6_u64;
    for second in 0..hours * 3_600 {
        b.session().set_legacy_clock_for_test(T0 + second * 1_000);
        take_in(b, &undecryptable(&id, now_secs())).await;
        if second % 72 == 0 {
            let (fix, _, _) = admin
                .circle
                .seal_location_for_test(&fx.group, &LocationMessage::new(1.0, 2.0))
                .await
                .expect("the peer seals");
            take_in(b, &fix).await;
        }
        if second % 3_600 == 1_800 {
            let _ = run_catchup_in_foreground(&b.circle, &relays, 30).await;
        }
        assert!(
            !b.session().stalled_for_test(&fx.group),
            "stalled at second {second}"
        );
    }
    assert!(
        b.session().stall_arms_for_test() <= usize::try_from(hours + 1).expect("hours"),
        "a flood armed {} walks in {hours} hours",
        b.session().stall_arms_for_test()
    );
    assert!(
        b.session().stall_arms_for_test() > 0,
        "premise: the flood armed walks"
    );
    assert_ne!(
        recovery(b, &fx.group, true).await,
        Some(RecoveryCause::Stalled),
        "a flood with a live peer names the circle stalled"
    );
}

/// Traffic older than this copy's Welcome is the group's history, not
/// evidence the device fell behind: however much of it arrives, nothing arms.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn traffic_older_than_the_join_is_no_stall_evidence() {
    let fx = setup_circle(2, &[RELAY]).await;
    let b = &fx.members[1];
    let id = routing(b, &fx.group).await;
    let before_the_join = now_secs() - 7 * 24 * 60 * 60;
    for _ in 0..16 {
        take_in(b, &undecryptable(&id, before_the_join)).await;
    }
    assert_eq!(b.session().stall_arms_for_test(), 0);
    // Control: the same envelopes, dated now, arm.
    for _ in 0..8 {
        take_in(b, &undecryptable(&id, now_secs())).await;
    }
    assert_eq!(b.session().stall_arms_for_test(), 1);
}

/// Security Rule 15: the detector's arm, the walk and the report write no
/// group id, event id or pubkey to any log sink.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stall_detection_writes_no_identifier_to_any_sink() {
    let behind = behind().await;
    let (fx, b) = (&behind.fx, &behind.fx.members[1]);
    let id = routing(b, &fx.group).await;
    let planted: Vec<Event> = (0..8).map(|_| undecryptable(&id, now_secs())).collect();
    let lines = Box::pin(helpers::capture_haven_log(async {
        b.session().set_legacy_clock_for_test(T0);
        for envelope in &planted {
            take_in(b, envelope).await;
        }
        for walk in 1..=3_u64 {
            if walk > 1 {
                b.session().set_legacy_clock_for_test(T0 + walk * HOUR_MS);
                take_in(b, &undecryptable(&id, now_secs())).await;
            }
            let _ = run_catchup_in_foreground(&b.circle, &behind.relays, 30).await;
        }
    }))
    .await;
    assert!(
        b.session().stalled_for_test(&fx.group),
        "premise: the report was reached"
    );
    let group_hex = hex::encode(fx.group.as_slice());
    let routing_hex = hex::encode(id);
    let event_hex = planted[0].id.to_hex();
    let pubkey_hex = b.pubkey_hex();
    helpers::assert_no_needles(
        &helpers::haven_core_lines(&lines),
        &[
            group_hex.as_str(),
            routing_hex.as_str(),
            event_hex.as_str(),
            pubkey_hex.as_str(),
            behind.url.as_str(),
        ],
    );
}
