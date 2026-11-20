//! A change of the device's network, as the live plane meets it: every
//! socket the old network carried still reads `Connected` to the pool, which
//! notices one is dead only when a ping goes unanswered, up to two ping
//! intervals later. `LiveSyncCore::reconnect_after_network_change` re-dials
//! both pools at once, through the pause and the foreground open.
//!
//! What is promised, each against fronts that black-hole the connections
//! open at the change (`RecordingFront::black_hole`) — open TCP, no FIN, no
//! pong, nothing handed on — while serving new ones:
//!
//! - both the engine pool and the inbox socket dial afresh before the call
//!   returns, and the circle's and the inbox's REQs ride the new connections;
//! - a location and an invitation the relays pushed into the dead sockets
//!   are delivered, the invitation after the new inbox socket authenticates,
//!   and a later location arrives live — all far inside the pool's own ping
//!   interval, so nothing but the re-dial can have delivered them;
//! - a caller that claims nothing is refused and nothing is touched, and a
//!   paused session is opened without a second pause;
//! - nothing a relay, a challenge, the identity key, a circle or a
//!   subscription id names reaches a log (Security Rule 15).

mod helpers;

use std::sync::Arc;
use std::time::Duration;

use haven_core::relay::live_sync::{
    CircleSpec, Claim, LiveSyncCore, LiveSyncError, LiveSyncEvent, StopOutcome, SyncStatusReason,
};
use haven_core::relay::recording_front::{RecordedFrame, RecordingFront};
use haven_core::relay::RelayManager;
use helpers::{
    assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines,
    setup_circle, CircleMember,
};
use nostr::{Event, EventBuilder, Keys, Kind, Tag, Timestamp};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tokio::sync::broadcast;

/// The longest a premise may take to hold, unscaled.
const WAIT: Duration = Duration::from_secs(20);

/// The longest a delivery after the re-dial may take, whatever the scale:
/// well inside `nostr-relay-pool`'s 55 s ping interval, past which a pool
/// that noticed a dead socket itself could deliver what this file credits to
/// the re-dial.
const DELIVERY: Duration = Duration::from_secs(40);

fn budget() -> Duration {
    WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

fn delivery() -> Duration {
    budget().min(DELIVERY)
}

/// Whether `wait` finished within the budget.
async fn within(wait: impl std::future::Future<Output = ()>) -> bool {
    tokio::time::timeout(budget(), wait).await.is_ok()
}

/// A gift wrap to `to`, stored an hour ago: opaque to everything here, which
/// reads it only as a delivery.
fn wrap_to(to: &Keys) -> Event {
    EventBuilder::new(Kind::GiftWrap, "opaque-sealed-rumor")
        .tags([Tag::public_key(to.public_key())])
        .custom_created_at(Timestamp::from(Timestamp::now().as_secs() - 3_600))
        .sign_with_keys(&Keys::generate())
        .expect("a locally built wrap signs")
}

/// Stores `event` on the relay at `url`, anonymously.
async fn store(url: &str, event: &Event) {
    let client = Client::builder().build();
    client.add_relay(url).await.expect("add relay");
    client.connect().await;
    client.send_event(event).await.expect("the relay stores it");
    client.shutdown().await;
}

type Wanted = Box<dyn Fn(&LiveSyncEvent) -> bool + Send + Sync>;

/// Waits, within `wait`, for the bus to deliver each event `wanted` picks
/// out, in whatever order they come, and answers which did.
async fn arrive(
    bus: &mut broadcast::Receiver<LiveSyncEvent>,
    wait: Duration,
    wanted: &[Wanted],
) -> Vec<bool> {
    let mut seen = vec![false; wanted.len()];
    let _ = tokio::time::timeout(wait, async {
        while seen.contains(&false) {
            match bus.recv().await {
                Ok(event) => {
                    for (at, wanted) in wanted.iter().enumerate() {
                        seen[at] |= wanted(&event);
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    })
    .await;
    seen
}

fn location(marker: &'static str) -> Wanted {
    Box::new(
        move |event| matches!(event, LiveSyncEvent::Location { content, .. } if content.contains(marker)),
    )
}

fn welcome(wrap: &Event) -> Wanted {
    let id = wrap.id.to_hex();
    Box::new(
        move |event| matches!(event, LiveSyncEvent::Welcome { gift_wrap_json } if gift_wrap_json.contains(&id)),
    )
}

/// `recorded`, parsed.
fn parsed(recorded: &[RecordedFrame]) -> Vec<(usize, serde_json::Value)> {
    recorded
        .iter()
        .filter(|frame| !frame.binary)
        .map(|frame| {
            (
                frame.conn,
                serde_json::from_str(&frame.text).expect("a client frame is JSON"),
            )
        })
        .collect()
}

fn filters(frame: &serde_json::Value) -> &[serde_json::Value] {
    frame
        .as_array()
        .and_then(|f| f.get(2..))
        .unwrap_or_default()
}

/// A circle's standing `#h` REQ: never the fetch by id a NIP-77 pass makes.
fn is_circle_req(frame: &serde_json::Value) -> bool {
    frame[0] == "REQ"
        && filters(frame)
            .iter()
            .any(|filter| filter.get("#h").is_some() && filter.get("ids").is_none())
}

/// The inbox REQ (`kinds: [1059]`).
fn is_inbox_req(frame: &serde_json::Value) -> bool {
    frame[0] == "REQ"
        && filters(frame)
            .iter()
            .any(|filter| filter["kinds"] == serde_json::json!([1059]))
}

/// Whether `front` recorded a frame `which` picks out on a connection
/// numbered `from` or later.
fn on_a_connection_from(
    which: fn(&serde_json::Value) -> bool,
    from: usize,
) -> impl Fn(&[RecordedFrame]) -> bool {
    move |recorded| {
        parsed(recorded)
            .iter()
            .any(|(conn, frame)| *conn >= from && which(frame))
    }
}

/// The subscription ids every `REQ`, `CLOSE` and `NEG-OPEN` the fronts
/// recorded carries.
fn subscription_ids(fronts: &[&RecordingFront]) -> Vec<String> {
    let mut ids: Vec<String> = fronts
        .iter()
        .flat_map(|front| parsed(&front.frames()))
        .filter(|(_, frame)| matches!(frame[0].as_str(), Some("REQ" | "CLOSE" | "NEG-OPEN")))
        .filter_map(|(_, frame)| frame[1].as_str().map(str::to_owned))
        .collect();
    ids.sort_unstable();
    ids.dedup();
    ids
}

/// The `Paused` and `BackgroundResumed` statuses already on `statuses`, in
/// order: what a call that has returned emitted.
fn lifecycle_statuses(statuses: &mut broadcast::Receiver<LiveSyncEvent>) -> Vec<SyncStatusReason> {
    let mut seen = Vec::new();
    loop {
        match statuses.try_recv() {
            Ok(LiveSyncEvent::Status { reason })
                if matches!(
                    reason,
                    SyncStatusReason::Paused | SyncStatusReason::BackgroundResumed
                ) =>
            {
                seen.push(reason);
            }
            Ok(_) | Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            Err(_) => return seen,
        }
    }
}

/// The one line the change logs, which the device lanes read as their
/// oracle that the re-dial ran.
const CHANGED: &str = "[live_sync] the network changed";

/// A network change while sockets the old network carried still read
/// `Connected`: the location and the invitation pushed into them are lost
/// with them, and the change's re-dial — both pools, before the call returns
/// — delivers both, the invitation once the new inbox socket has
/// authenticated, and keeps the circle live on the new connection.
#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn a_network_change_redials_both_pools_and_delivers_what_was_pushed_into_the_dead_sockets() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let circle_relay = MockRelay::run().await.expect("circle relay");
    let circle_relay_url = circle_relay.url().await.to_string();
    let inbox_relay = MockRelay::run().await.expect("inbox relay");
    let inbox_relay_url = inbox_relay.url().await.to_string();
    let engine_front = RecordingFront::start(&circle_relay_url);
    let inbox_front = RecordingFront::start_gating(&inbox_relay_url);
    let fx = setup_circle(2, &[engine_front.url()]).await;
    let (me, peer) = (fx.admin(), &fx.members[1]);
    let ngid = hex::encode(
        me.circle
            .get_circle(&fx.group)
            .await
            .expect("the circle store is read")
            .expect("the circle exists")
            .circle
            .nostr_group_id,
    );
    let sealed = |latitude: f64| helpers::drive::sealed_by(peer, &fx.group, latitude);
    store(&circle_relay_url, &sealed(10.5).await).await;
    let before_wrap = wrap_to(&me.keys);
    store(&inbox_relay_url, &before_wrap).await;

    let core = LiveSyncCore::new_local(Arc::clone(&me.circle), Arc::new(RelayManager::new()));
    let mut bus = core.bus().subscribe();
    let mut statuses = core.bus().subscribe();
    let lost_wrap = wrap_to(&me.keys);
    let mut lifecycle = Vec::new();
    let mut lines = capture_haven_log_here(async {
        core.start(
            &[CircleSpec {
                group_id_hex: ngid.clone(),
                relays: vec![engine_front.url().to_owned()],
            }],
            &[inbox_front.url().to_owned()],
        )
        .await
        .expect("start");
        // The circle's REQ stands at the relay, and the inbox socket has
        // authenticated and its asked-again REQ stands: a gating front serves
        // a gift wrap to nothing else.
        assert_eq!(
            arrive(
                &mut bus,
                budget(),
                &[location("10.5"), welcome(&before_wrap)]
            )
            .await,
            [true, true],
            "premise: both REQs stand on the connections about to go dead"
        );

        let (engine_dialled, inbox_dialled) =
            (engine_front.connections(), inbox_front.connections());
        engine_front.black_hole();
        inbox_front.black_hole();
        store(&circle_relay_url, &sealed(20.5).await).await;
        store(&inbox_relay_url, &lost_wrap).await;
        assert!(
            within(engine_front.wait_swallowed(1)).await
                && within(inbox_front.wait_swallowed(1)).await,
            "premise: the relays pushed both events into the dead sockets"
        );
        let _ = lifecycle_statuses(&mut statuses);

        core.reconnect_after_network_change(Claim::Foreground)
            .await
            .expect("the re-dial opens the session");
        assert!(
            engine_front.connections() > engine_dialled
                && inbox_front.connections() > inbox_dialled,
            "the change returned before both pools had dialled afresh"
        );
        lifecycle = lifecycle_statuses(&mut statuses);
        assert!(
            within(engine_front.wait_for(on_a_connection_from(is_circle_req, engine_dialled)))
                .await
                && within(inbox_front.wait_for(on_a_connection_from(is_inbox_req, inbox_dialled)))
                    .await,
            "the circle's or the inbox's REQ did not ride a new connection"
        );
        assert_eq!(
            arrive(
                &mut bus,
                delivery(),
                &[location("20.5"), welcome(&lost_wrap)]
            )
            .await,
            [true, true],
            "the location or the invitation pushed into the dead sockets was not delivered \
             after the re-dial, the invitation once the new inbox socket authenticated"
        );
        store(&circle_relay_url, &sealed(30.5).await).await;
        assert_eq!(
            arrive(&mut bus, delivery(), &[location("30.5")]).await,
            [true],
            "a location after the re-dial did not arrive live on the new connection"
        );
    })
    .await;
    assert_eq!(
        lifecycle,
        [
            SyncStatusReason::Paused,
            SyncStatusReason::BackgroundResumed
        ],
        "the change is not one pause and one open"
    );

    lines = haven_core_lines(&lines);
    assert_some_line_from(&lines, "haven_core::relay::live_sync");
    assert_eq!(
        lines
            .iter()
            .filter(|line| line.message.contains(CHANGED))
            .count(),
        1,
        "the change logged its fixed line other than once"
    );
    let mut needles = vec![
        engine_front.url().to_owned(),
        inbox_front.url().to_owned(),
        circle_relay_url.clone(),
        inbox_relay_url.clone(),
        me.pubkey_hex(),
        ngid.clone(),
        hex::encode(fx.group.as_slice()),
    ];
    needles.extend((0..inbox_front.connections()).map(|conn| format!("challenge-{conn}")));
    needles.extend(subscription_ids(&[&engine_front, &inbox_front]));
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_no_needles(&lines, &needles);

    assert_eq!(core.stop().await, StopOutcome::Drained);
}

/// A session over one circle at `circle_front` and one inbox relay at
/// `inbox_front`, whose REQs both stand.
async fn live_session(
    member: &CircleMember,
    circle_front: &RecordingFront,
    inbox_front: &RecordingFront,
) -> LiveSyncCore {
    member.circle.keep_circle_row_for_test([0x5c; 32]);
    let core = LiveSyncCore::new_local(Arc::clone(&member.circle), Arc::new(RelayManager::new()));
    core.start(
        &[CircleSpec {
            group_id_hex: hex::encode([0x5c_u8; 32]),
            relays: vec![circle_front.url().to_owned()],
        }],
        &[inbox_front.url().to_owned()],
    )
    .await
    .expect("start");
    assert!(
        within(circle_front.wait_for(on_a_connection_from(is_circle_req, 0))).await
            && within(inbox_front.wait_for(on_a_connection_from(is_inbox_req, 0))).await,
        "premise: both REQs went out"
    );
    core
}

/// What a session shows of its sockets and REQs.
async fn shown(
    core: &LiveSyncCore,
    fronts: [&RecordingFront; 2],
) -> (bool, usize, usize, [usize; 2]) {
    (
        core.is_paused(),
        core.pool_subscription_count().await,
        core.relay_health().await.connected,
        fronts.map(RecordingFront::connections),
    )
}

/// A change reported by a caller that claims nothing — the app not in front
/// of its user — is refused, live or paused, and touches nothing: no REQ is
/// closed, no socket cut or dialled, no status emitted.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_network_change_claimed_by_nobody_touches_nothing() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let circle_relay = MockRelay::run().await.expect("circle relay");
    let inbox_relay = MockRelay::run().await.expect("inbox relay");
    let circle_front = RecordingFront::start(circle_relay.url().await.as_str());
    let inbox_front = RecordingFront::start(inbox_relay.url().await.as_str());
    let member = CircleMember::new();
    let core = live_session(&member, &circle_front, &inbox_front).await;
    let mut statuses = core.bus().subscribe();

    for state in ["live", "paused"] {
        if state == "paused" {
            core.pause_subscriptions().await.expect("pause");
            let _ = lifecycle_statuses(&mut statuses);
        }
        let before = shown(&core, [&circle_front, &inbox_front]).await;
        assert!(
            matches!(
                core.reconnect_after_network_change(Claim::Nothing).await,
                Err(LiveSyncError::NotForeground)
            ),
            "{state}: a change nobody claimed was not refused as such"
        );
        assert_eq!(
            shown(&core, [&circle_front, &inbox_front]).await,
            before,
            "{state}: a change nobody claimed touched the session's sockets or REQs"
        );
        assert!(
            lifecycle_statuses(&mut statuses).is_empty(),
            "{state}: a change nobody claimed paused or opened the session"
        );
    }
    assert_eq!(core.stop().await, StopOutcome::Drained);
}

/// A change met while the session is already paused opens it without a
/// second pause: the pause has cut every socket, so the open alone dials
/// both pools afresh.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_network_change_on_a_paused_session_opens_it_without_a_second_pause() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let circle_relay = MockRelay::run().await.expect("circle relay");
    let inbox_relay = MockRelay::run().await.expect("inbox relay");
    let circle_front = RecordingFront::start(circle_relay.url().await.as_str());
    let inbox_front = RecordingFront::start(inbox_relay.url().await.as_str());
    let member = CircleMember::new();
    let core = live_session(&member, &circle_front, &inbox_front).await;
    let mut statuses = core.bus().subscribe();
    core.pause_subscriptions().await.expect("pause");
    let _ = lifecycle_statuses(&mut statuses);
    let (paused, subscriptions, connected, [circle_dialled, inbox_dialled]) =
        shown(&core, [&circle_front, &inbox_front]).await;
    assert_eq!(
        (paused, subscriptions, connected),
        (true, 0, 0),
        "premise: paused"
    );

    core.reconnect_after_network_change(Claim::Foreground)
        .await
        .expect("the change opens the paused session");
    assert_eq!(
        lifecycle_statuses(&mut statuses),
        [SyncStatusReason::BackgroundResumed],
        "a change on a paused session paused it again, or did not open it"
    );
    let (paused, subscriptions, connected, [circle_now, inbox_now]) =
        shown(&core, [&circle_front, &inbox_front]).await;
    assert!(
        !paused && subscriptions > 0 && connected > 0,
        "the change left the session paused, or without REQs or sockets"
    );
    assert!(
        circle_now > circle_dialled && inbox_now > inbox_dialled,
        "the open did not dial both pools afresh"
    );
    assert!(
        within(inbox_front.wait_for(on_a_connection_from(is_inbox_req, inbox_dialled))).await
            && within(circle_front.wait_for(on_a_connection_from(is_circle_req, circle_dialled)))
                .await,
        "the REQs did not ride the new connections"
    );
    assert_eq!(core.stop().await, StopOutcome::Drained);
}
