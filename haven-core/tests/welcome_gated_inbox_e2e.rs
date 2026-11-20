//! A Welcome reaches an invitee whose first inbox relay takes gift wraps and
//! never serves them to a client that has not authenticated — as
//! `relay.damus.io` does under strfry's default `restrictedReadKinds` — even
//! when the invitee's read answers no challenge.
//!
//! The founder's product driver sends the founding Welcome through its own
//! publish pool to in-process relays; the gated one sits behind a gating
//! recording front (`relay::recording_front`), which answers a gift-wrap read
//! as strfry does and hands every write on. The invitee reads its inbox per
//! relay through an anonymous pool (`RelayManager::fetch_events_per_relay`;
//! the Invitations page's own read answers the challenge,
//! `own_inbox_read_e2e`), and joins from what it read.
//!
//! One test, one world: the loopback opt-in it installs is install-once. No
//! wait here is a sleep: each awaits a product outcome, bounded by a budget
//! scaled for instrumented runs.

mod helpers;

use std::time::Duration;

use haven_core::circle::CircleConfig;
use haven_core::relay::fanout::{DriveMode, Publishing, WallClock};
use haven_core::relay::recording_front::{RecordedFrame, RecordingFront};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use helpers::{create_key_package_event, CircleMember};
use nostr::{Filter, Kind};
use nostr_relay_builder::MockRelay;

/// The longest a product outcome may take, unscaled.
const WAIT: Duration = Duration::from_mins(1);

fn budget() -> Duration {
    WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(budget(), fut)
        .await
        .unwrap_or_else(|_| panic!("{what} did not finish within its budget"))
}

/// The gift wraps `frames` published, by event id.
fn published_wraps(frames: &[RecordedFrame]) -> Vec<String> {
    frames
        .iter()
        .filter_map(|frame| serde_json::from_str::<serde_json::Value>(&frame.text).ok())
        .filter(|frame| frame[0] == "EVENT" && frame[1]["kind"] == 1059)
        .filter_map(|frame| frame[1]["id"].as_str().map(str::to_owned))
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_reaches_an_invitee_whose_first_inbox_relay_gates_gift_wrap_reads() {
    let _ = allow_ws_loopback_for_test();
    let gated_store = MockRelay::run().await.expect("a relay");
    let plain_store = MockRelay::run().await.expect("a relay");
    let location = MockRelay::run().await.expect("a relay");
    let gated = RecordingFront::start_gating(gated_store.url().await.as_str());
    let plain = RecordingFront::start(plain_store.url().await.as_str());
    let inbox = vec![gated.url().to_owned(), plain.url().to_owned()];

    let invitee = CircleMember::new();
    let package = haven_core::circle::MemberKeyPackage {
        key_package_event: create_key_package_event(invitee.session(), &invitee.keys, &inbox).await,
        inbox_relays: inbox.clone(),
        nip65_relays: Vec::new(),
        nip65_write_relays: Vec::new(),
    };
    let founder = CircleMember::new();
    let pool = RelayManager::new();
    let transport = pool.fanout_transport();
    let driver = Publishing {
        fanout: &transport,
        publisher: &pool,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let config =
        CircleConfig::new("Gated inbox").with_relays(vec![location.url().await.to_string()]);
    let created = within(
        "the create",
        Box::pin(driver.create_circle(&founder.circle, &founder.keys, vec![package], &config)),
    )
    .await
    .expect("the circle is created");
    assert_eq!(
        (created.welcomes_sent, created.welcomes_total),
        (1, 1),
        "premise: a relay acknowledged the Welcome",
    );
    assert_eq!(
        published_wraps(&gated.frames()).len(),
        1,
        "premise: the gated relay was sent the Welcome, and took it",
    );
    // Compared, never rendered: a failure must not print an event id.
    assert!(
        published_wraps(&plain.frames()) == published_wraps(&gated.frames()),
        "the Welcome was not sent to the inbox relay its invitee can read",
    );

    let reader = RelayManager::new();
    let filter = Filter::new()
        .kind(Kind::GiftWrap)
        .pubkey(invitee.keys.public_key());
    let outcomes = within(
        "the inbox read",
        reader.fetch_events_per_relay(filter, &inbox),
    )
    .await
    .expect("the read runs");
    let [from_gated, from_plain] =
        <[_; 2]>::try_from(outcomes).unwrap_or_else(|_| panic!("one answer per inbox relay"));
    assert!(
        !from_gated.drained && from_gated.events.is_empty(),
        "premise: the gated relay served a gift wrap to a client that never authenticated",
    );
    assert_eq!(
        gated.refused().len(),
        1,
        "premise: the gated relay did not refuse the invitee's read",
    );
    assert!(
        from_plain.drained,
        "the readable inbox relay did not end its answer"
    );
    let [wrap] = <[_; 1]>::try_from(from_plain.events)
        .unwrap_or_else(|_| panic!("the readable inbox relay does not hold the one Welcome"));

    let invitation = invitee
        .circle
        .process_gift_wrapped_invitation(&invitee.keys, &wrap)
        .await
        .expect("the Welcome read is an invitation");
    assert!(
        invitation.inviter_pubkey == founder.pubkey_hex(),
        "the invitation does not name its inviter",
    );
    let joined = invitee
        .circle
        .accept_invitation(&wrap.id)
        .await
        .expect("the invitee joins from the Welcome it read");
    assert!(
        joined.circle.mls_group_id == created.circle.mls_group_id,
        "the invitee joined some other circle",
    );
}
