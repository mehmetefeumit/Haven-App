//! The live plane's inbox socket: the `kind:1059` `#p` REQ on a pool of its
//! own that answers a relay's NIP-42 challenge as the identity, while every
//! circle's `#h` REQ stays on the engine pool, which never does.
//!
//! What is promised, each against a front that plays strfry's gift-wrap gate
//! and checks the answer itself (`RecordingFront::start_gating_with`):
//!
//! - an invitation stored only on a gating relay, older than the inbox
//!   lookback the cursor allows once another relay's `EOSE` advanced it, is
//!   still delivered on the live plane after the socket authenticates —
//!   because the gating relay owes the inbox from the `since` it was first
//!   asked, durably, across a restart (Security Rule 12);
//! - the refused REQ is asked again exactly once per authentication, whether
//!   the pool deleted it (strfry's wrapped `ERROR: auth-required:`) or kept it
//!   (an unwrapped `auth-required:`), and strfry's `already authenticated` to
//!   a second challenge's answer changes nothing;
//! - no `AUTH` ever leaves on an engine socket, and no `#h` REQ ever rides the
//!   inbox socket;
//! - nothing a relay, a challenge, the identity key or a subscription id
//!   names reaches a log (Security Rule 15).

mod helpers;

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::cursor::STREAM_INBOX_1059;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore, LiveSyncEvent, StopOutcome};
use haven_core::relay::recording_front::{Gate, RecordingFront};
use haven_core::relay::RelayManager;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines};
use nostr::{Event, EventBuilder, Keys, Kind, RelayUrl, Tag, Timestamp};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;
use tokio::sync::broadcast;

const DAY: u64 = 86_400;

/// The longest anything here may take to arrive, unscaled.
const WAIT: Duration = Duration::from_secs(20);

fn budget() -> Duration {
    WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

fn now() -> u64 {
    Timestamp::now().as_secs()
}

/// The front's address as the floors key it: the dialled `RelayUrl`.
fn relay_key(url: &str) -> String {
    RelayUrl::parse(url)
        .expect("a relay url")
        .as_str()
        .to_owned()
}

/// A gift wrap to `to`, stored `age_secs` ago: opaque to everything here,
/// which reads it only as a delivery.
fn wrap_to(to: &Keys, age_secs: u64) -> Event {
    EventBuilder::new(Kind::GiftWrap, "opaque-sealed-rumor")
        .tags([Tag::public_key(to.public_key())])
        .custom_created_at(Timestamp::from(now() - age_secs))
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

/// Polls `done` until it holds or the budget runs out.
async fn until(mut done: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + budget();
    while tokio::time::Instant::now() < deadline {
        if done() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    done()
}

/// Waits for the bus to deliver `wrap` as a Welcome.
async fn delivered(bus: &mut broadcast::Receiver<LiveSyncEvent>, wrap: &Event) -> bool {
    let id = wrap.id.to_hex();
    tokio::time::timeout(budget(), async {
        loop {
            match bus.recv().await {
                Ok(LiveSyncEvent::Welcome { gift_wrap_json }) if gift_wrap_json.contains(&id) => {
                    return true
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return false,
            }
        }
    })
    .await
    .unwrap_or(false)
}

/// The parsed frames the front recorded.
fn frames(front: &RecordingFront) -> Vec<(usize, serde_json::Value)> {
    front
        .frames()
        .into_iter()
        .filter(|frame| !frame.binary)
        .map(|frame| {
            (
                frame.conn,
                serde_json::from_str(&frame.text).expect("a client frame is JSON"),
            )
        })
        .collect()
}

/// How many inbox REQs (`kinds: [1059]`) the front was sent.
fn inbox_reqs(front: &RecordingFront) -> usize {
    frames(front)
        .iter()
        .filter(|(_, frame)| {
            frame[0] == "REQ"
                && frame.as_array().is_some_and(|f| {
                    f[2..]
                        .iter()
                        .any(|filter| filter["kinds"] == serde_json::json!([1059]))
                })
        })
        .count()
}

struct Invitee {
    keys: Keys,
    dir: TempDir,
    circle: Arc<CircleManager>,
}

/// An invitee whose inbox cursor says it last heard an inbox `EOSE` six days
/// ago: it was offline since.
fn six_days_offline() -> Invitee {
    let keys = Keys::generate();
    let dir = TempDir::new().expect("temp dir");
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    let six_days_ago_ms = i64::try_from((now() - 6 * DAY) * 1000).expect("ms");
    circle
        .advance_sync_cursor(STREAM_INBOX_1059, six_days_ago_ms)
        .expect("cursor");
    Invitee { keys, dir, circle }
}

/// The inbox cursor's instant, in seconds.
fn cursor_secs(circle: &CircleManager) -> u64 {
    circle
        .read_sync_cursor(STREAM_INBOX_1059)
        .ok()
        .flatten()
        .map_or(0, |ms| u64::try_from(ms / 1000).unwrap_or(0))
}

/// H1: an invitation stored five days ago only on a gating relay is delivered
/// to an invitee six days offline once its inbox socket authenticates — after
/// a plain relay's `EOSE` has already advanced the inbox cursor to now, which
/// alone would ask the gating relay only four days back. The gating relay's
/// floor, recorded before the first REQ, is what reaches the invitation; and
/// none of the identifiers involved reaches a log.
#[tokio::test]
async fn a_gated_invitation_older_than_the_advanced_lookback_is_delivered_after_auth() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let plain = MockRelay::run().await.expect("plain relay");
    let plain_url = plain.url().await.to_string();
    let gated = MockRelay::run().await.expect("gated relay");
    let front = RecordingFront::start_gating_with(
        gated.url().await.as_str(),
        Gate {
            hold_challenges: true,
            ..Gate::default()
        },
    );
    let me = six_days_offline();
    let wrap = wrap_to(&me.keys, 5 * DAY);
    store(gated.url().await.as_str(), &wrap).await;

    let core = LiveSyncCore::new_local(Arc::clone(&me.circle), Arc::new(RelayManager::new()));
    let mut bus = core.bus().subscribe();
    let mut got = false;
    let lines = capture_haven_log_here(async {
        core.start(&[], &[plain_url.clone(), front.url().to_owned()])
            .await
            .expect("start");
        // The plain relay's `EOSE` advances the cursor past the invitation's
        // window, while the gating relay has refused and not yet challenged.
        assert!(
            until(|| cursor_secs(&me.circle) + 60 > now() && !front.refused().is_empty()).await,
            "the plain relay's EOSE must advance the inbox cursor first, and the gating \
             relay must have refused, or this proves nothing about the floor"
        );
        let floor = me
            .circle
            .inbox_floor_for_test(&relay_key(front.url()))
            .expect("the refusing relay owes the inbox from the since it was asked");
        assert!(
            u64::try_from(floor).expect("floor") <= wrap.created_at.as_secs(),
            "the floor reaches back past the invitation"
        );
        front.release_challenges();
        got = delivered(&mut bus, &wrap).await;
    })
    .await;
    assert!(
        got,
        "the invitation was not delivered after the inbox socket authenticated"
    );
    assert!(
        until(|| me
            .circle
            .inbox_floor_for_test(&relay_key(front.url()))
            .is_none())
        .await,
        "the EOSE to the REQ asked from the floor ends the floor"
    );

    let lines = haven_core_lines(&lines);
    assert_some_line_from(&lines, "haven_core::relay::live_sync");
    let pubkey = me.keys.public_key().to_hex();
    let mut needles = vec![
        front.url().to_owned(),
        plain_url.clone(),
        "challenge-0".to_owned(),
        pubkey,
    ];
    needles.extend(
        frames(&front)
            .iter()
            .filter(|(_, frame)| frame[0] == "REQ")
            .map(|(_, frame)| frame[1].as_str().unwrap_or_default().to_owned()),
    );
    let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
    assert_no_needles(&lines, &needles);

    assert_eq!(core.stop().await, StopOutcome::Drained);
}

/// The floor is durable: a session that ends before the gating relay is ever
/// answered leaves it owed, and the next session — on a manager reopened over
/// the same store, whose cursor another relay advanced to now — asks the
/// gating relay from it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_gated_relays_floor_survives_a_restart() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let plain = MockRelay::run().await.expect("plain relay");
    let plain_url = plain.url().await.to_string();
    let gated = MockRelay::run().await.expect("gated relay");
    let front = RecordingFront::start_gating_with(
        gated.url().await.as_str(),
        Gate {
            hold_challenges: true,
            ..Gate::default()
        },
    );
    let me = six_days_offline();
    let wrap = wrap_to(&me.keys, 5 * DAY);
    store(gated.url().await.as_str(), &wrap).await;
    let inbox = [plain_url.clone(), front.url().to_owned()];

    let first = LiveSyncCore::new_local(Arc::clone(&me.circle), Arc::new(RelayManager::new()));
    first.start(&[], &inbox).await.expect("start");
    assert!(
        until(|| cursor_secs(&me.circle) + 60 > now() && !front.refused().is_empty()).await,
        "the cursor must advance and the gating relay refuse before the restart"
    );
    assert_eq!(first.stop().await, StopOutcome::Drained);
    drop(first);
    let Invitee { keys, dir, circle } = me;
    drop(circle);

    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("reopen"));
    assert!(
        cursor_secs(&circle) + 60 > now(),
        "the advanced cursor is what the restart reads"
    );
    front.release_challenges();
    let second = LiveSyncCore::new_local(Arc::clone(&circle), Arc::new(RelayManager::new()));
    let mut bus = second.bus().subscribe();
    second.start(&[], &inbox).await.expect("restart");
    assert!(
        delivered(&mut bus, &wrap).await,
        "the restarted session forgot what the gating relay owes the inbox"
    );
    assert_eq!(second.stop().await, StopOutcome::Drained);
}

/// Exactly one REQ follows the authentication — Haven's re-issue for a REQ
/// the pool deleted, the pool's own resend for one it kept — and no repair
/// is left pending to send another; with `challenge_again`, strfry's `OK
/// false` to the second answer changes nothing.
async fn exactly_one_more_req(gate: Gate) {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let gated = MockRelay::run().await.expect("gated relay");
    let front = RecordingFront::start_gating_with(gated.url().await.as_str(), gate);
    let keys = Keys::generate();
    let dir = TempDir::new().expect("temp dir");
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    let wrap = wrap_to(&keys, 3_600);
    store(gated.url().await.as_str(), &wrap).await;

    let core = LiveSyncCore::new_local(Arc::clone(&circle), Arc::new(RelayManager::new()));
    let mut bus = core.bus().subscribe();
    core.start(&[], &[front.url().to_owned()])
        .await
        .expect("start");
    assert!(
        delivered(&mut bus, &wrap).await,
        "the gated invitation was never delivered"
    );
    assert!(
        until(|| circle
            .inbox_floor_for_test(&relay_key(front.url()))
            .is_none())
        .await,
        "the asked-again REQ must end with its EOSE"
    );
    if gate.challenge_again {
        assert!(
            until(|| frames(&front)
                .iter()
                .filter(|(_, f)| f[0] == "AUTH")
                .count()
                == 2)
            .await,
            "the second challenge was answered, and refused as a repeat"
        );
    }
    assert_eq!(
        inbox_reqs(&front),
        2,
        "the refused REQ and exactly one more: never both the pool's resend and Haven's"
    );
    assert_eq!(
        core.repairs_pending_for_test(),
        0,
        "no gated repair may stay pending to ask a third time"
    );
    assert_eq!(core.stop().await, StopOutcome::Drained);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_req_the_pool_deleted_is_re_issued_once_after_auth() {
    exactly_one_more_req(Gate::default()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_req_the_pool_kept_is_resent_by_the_pool_alone_after_auth() {
    exactly_one_more_req(Gate {
        unwrapped: true,
        ..Gate::default()
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_answer_refused_as_a_repeat_changes_nothing() {
    exactly_one_more_req(Gate {
        challenge_again: true,
        ..Gate::default()
    })
    .await;
}

/// One relay that is both a circle's and the inbox's, and challenges every
/// connection the moment it opens: the engine socket carries the `#h` REQ
/// and never answers; the inbox socket answers and carries no `#h` REQ.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_engine_socket_never_authenticates_and_the_inbox_socket_carries_no_circle() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("relay");
    let front = RecordingFront::start_gating_with(
        relay.url().await.as_str(),
        Gate {
            challenge_on_connect: true,
            ..Gate::default()
        },
    );
    let keys = Keys::generate();
    let dir = TempDir::new().expect("temp dir");
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    circle.keep_circle_row_for_test([0x33; 32]);
    let wrap = wrap_to(&keys, 3_600);
    store(relay.url().await.as_str(), &wrap).await;

    let core = LiveSyncCore::new_local(Arc::clone(&circle), Arc::new(RelayManager::new()));
    let mut bus = core.bus().subscribe();
    core.start(
        &[CircleSpec {
            group_id_hex: hex::encode([0x33u8; 32]),
            relays: vec![front.url().to_owned()],
        }],
        &[front.url().to_owned()],
    )
    .await
    .expect("start");
    assert!(
        delivered(&mut bus, &wrap).await,
        "the inbox socket was never served"
    );

    let frames = frames(&front);
    let names_h = |frame: &serde_json::Value| {
        frame[0] == "REQ"
            && frame
                .as_array()
                .is_some_and(|f| f[2..].iter().any(|filter| filter.get("#h").is_some()))
    };
    let circle_conns: Vec<usize> = frames
        .iter()
        .filter(|(_, f)| names_h(f))
        .map(|(conn, _)| *conn)
        .collect();
    let auth_conns: Vec<usize> = frames
        .iter()
        .filter(|(_, f)| f[0] == "AUTH")
        .map(|(conn, _)| *conn)
        .collect();
    assert!(!circle_conns.is_empty(), "the circle's REQ went out");
    assert!(
        !auth_conns.is_empty(),
        "the inbox socket answered its challenge"
    );
    assert!(
        circle_conns.iter().all(|conn| !auth_conns.contains(conn)),
        "a socket carrying a circle's #h REQ answered a NIP-42 challenge"
    );
    let answer: Event = nostr::JsonUtil::from_json(
        frames
            .iter()
            .find(|(_, f)| f[0] == "AUTH")
            .map(|(_, f)| f[1].to_string())
            .expect("an answer"),
    )
    .expect("an AUTH event");
    assert_eq!(
        answer.pubkey,
        keys.public_key(),
        "the answer is the identity's"
    );
    assert_eq!(answer.kind, Kind::Authentication);
    assert_eq!(core.stop().await, StopOutcome::Drained);
}

/// Between background bursts neither pool holds a subscription or a
/// connected relay: the inbox socket is paused, counted and cut with the
/// engine's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pause_leaves_the_inbox_socket_with_no_req_and_no_connection() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let circle_relay = MockRelay::run().await.expect("circle relay");
    let inbox_relay = MockRelay::run().await.expect("inbox relay");
    let inbox_front = RecordingFront::start(inbox_relay.url().await.as_str());
    let keys = Keys::generate();
    let dir = TempDir::new().expect("temp dir");
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("circle"));
    circle.keep_circle_row_for_test([0x44; 32]);

    let core = LiveSyncCore::new_local(Arc::clone(&circle), Arc::new(RelayManager::new()));
    core.start(
        &[CircleSpec {
            group_id_hex: hex::encode([0x44u8; 32]),
            relays: vec![circle_relay.url().await.to_string()],
        }],
        &[inbox_front.url().to_owned()],
    )
    .await
    .expect("start");
    assert!(
        until(|| inbox_reqs(&inbox_front) == 1).await,
        "the inbox REQ went out on its own socket"
    );
    let live = core.relay_health().await;
    assert_eq!(
        (live.total, live.connected),
        (2, 2),
        "one socket per pool while live"
    );

    for burst in 0..2 {
        core.pause_subscriptions().await.expect("pause");
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "burst {burst}: a REQ stood"
        );
        assert_eq!(
            core.relay_health().await.connected,
            0,
            "burst {burst}: a socket stood"
        );
        assert!(
            until(|| inbox_front.closed() == inbox_front.connections()).await,
            "burst {burst}: the inbox socket was left open at the relay"
        );
        core.open_background_burst().await.expect("burst opens");
    }
    assert_eq!(core.stop().await, StopOutcome::Drained);
}
