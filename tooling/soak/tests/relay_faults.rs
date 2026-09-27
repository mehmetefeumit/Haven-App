//! Every fault in the catalogue, proven on the wire.
//!
//! Each case has a positive control — the fault observably changes what a real
//! `nostr_sdk::Client` sees — and a negative one: healing puts the pass-through
//! back. A fault asserted only by "the rig was asked for it" would make every
//! liveness bound derived from it a fiction, and a heal asserted only by "the
//! flag is clear" would make every recovery scenario vacuous.
//!
//! The client here is the real SDK against the real plane, and the assertions
//! are about frames. Haven's own de-duplication is NOT in the picture: the
//! pool's 35 000-id tracker sits between these frames and any Haven code, which
//! is exactly why a wire-level proof is the thing to have.

use std::sync::atomic::AtomicUsize;
use std::sync::Arc;
use std::time::Duration;

use haven_soak::nemesis::types::{ByteCap, ClosedPrefix, DropClass, Fault, Schedule};
use haven_soak::profiles::WorldShape;
use haven_soak::relay::{mint, Forgery, Ledger, NativeClosed, SimRelay, OVERSIZE_PREFIX};
use haven_soak::rig::circle::{build_circle, publish_witnessed};
use haven_soak::rig::{
    install_process_globals, poll_until, CapturedLine, CircleTag, DeviceTag, EventTag, LogDrain,
    RelayPlane, RelayTag, RigError, SimDevice, SimWorld,
};
use haven_soak::timeline::Timeline;
use nostr::{
    ClientMessage, Event, EventBuilder, EventId, Filter, JsonUtil, Keys, Kind, RelayMessage,
    SubscriptionId, Tag, Timestamp,
};
use nostr_sdk::{Client, RelayPoolNotification};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::sync::broadcast;

/// A loopback relay that has not answered inside this is not slow but broken.
/// Every absence window in this file is the same bound, and the positive
/// control that shares the test is what proves the window is long enough.
const WIRE_BOUND: Duration = Duration::from_secs(5);
/// How often a ledger predicate is re-read.
const POLL_EVERY: Duration = Duration::from_millis(5);
/// The text a `Notice` fault carries. Harness-authored, like every string this
/// crate puts on a wire.
const NOTICE_TEXT: &str = "the harness is holding this relay";

/// A world here captures no logs: the case is about frames.
struct NoDrain;

impl LogDrain for NoDrain {
    fn drain_since(&self, _from: u64) -> Vec<CapturedLine> {
        Vec::new()
    }
}

// ---------------------------------------------------------------------------
// The world each case builds
// ---------------------------------------------------------------------------

async fn plane() -> SimRelay {
    SimRelay::start(RelayTag::new(0))
        .await
        .expect("a plane starts")
}

async fn connected_client(plane: &SimRelay) -> Client {
    let client = Client::builder().build();
    // These clients are wire observers: an automatic NIP-42 exchange would add
    // frames the case did not ask for, and one of them authenticates against
    // the very knob the byte-fidelity control is measuring.
    client.automatic_authentication(false);
    client
        .add_relay(plane.url())
        .await
        .expect("the client takes the plane's address");
    client.connect().await;
    client.wait_for_connection(WIRE_BOUND).await;
    client
}

fn an_event(text: &str) -> Event {
    EventBuilder::text_note(text)
        .sign_with_keys(&Keys::generate())
        .expect("a note signs")
}

fn an_event_at(text: &str, seconds_ago: u64) -> Event {
    EventBuilder::text_note(text)
        .custom_created_at(Timestamp::from(Timestamp::now().as_secs() - seconds_ago))
        .sign_with_keys(&Keys::generate())
        .expect("a note signs")
}

/// A note by `keys`, dated so the relay's own page order is deterministic.
fn a_note_by(keys: &Keys, text: &str, seconds_ago: u64) -> Event {
    EventBuilder::text_note(text)
        .custom_created_at(Timestamp::from(Timestamp::now().as_secs() - seconds_ago))
        .sign_with_keys(keys)
        .expect("a note signs")
}

/// A kind-445 APPLICATION message: the NIP-40 `expiration` the engine stamps
/// on one is what tells it from a commit on the wire.
fn an_application_445() -> Event {
    EventBuilder::new(Kind::Custom(445), "a location's ciphertext")
        .tag(Tag::expiration(Timestamp::from(
            Timestamp::now().as_secs() + 228,
        )))
        .sign_with_keys(&Keys::generate())
        .expect("a 445 signs")
}

/// A routing id standing in for a circle's public `#h`. No world here holds
/// one, and a forgery needs nothing else to be mintable — which is the point
/// every injection case is making.
const A_CIRCLES_ROUTING_ID: [u8; 32] = [0x3b; 32];

/// The same event with one byte of its signature turned over.
///
/// The relay's OWN refusal path: `nostr-relay-builder` verifies before it
/// saves, so this is refused with a machine-readable `invalid:` of its own
/// composition — which is what a forged refusal is compared against.
fn corrupt_the_signature_of(event: &Event) -> Event {
    let mut json: serde_json::Value =
        serde_json::from_str(&event.as_json()).expect("an event is JSON");
    let signature = json["sig"].as_str().expect("an event carries a sig");
    let mut bytes = signature.to_owned();
    // The last hex digit, moved: still 64 bytes of hex, still a well-formed
    // envelope, and no longer a signature over this event.
    let last = bytes.pop().expect("a signature is not empty");
    bytes.push(if last == '0' { '1' } else { '0' });
    json["sig"] = serde_json::Value::String(bytes);
    Event::from_json(json.to_string()).expect("the envelope still parses")
}

/// A kind-445 COMMIT: the same kind, no expiration — group history has to
/// outlive any TTL.
fn a_commit_445() -> Event {
    EventBuilder::new(Kind::Custom(445), "a commit's ciphertext")
        .sign_with_keys(&Keys::generate())
        .expect("a 445 signs")
}

async fn publish(client: &Client, plane: &SimRelay, event: &Event) {
    publish_on(client, plane.url(), event).await;
}

/// Publishes through the one endpoint `client` dialled, canonical or a
/// device's own.
async fn publish_on(client: &Client, url: &str, event: &Event) {
    client
        .send_msg_to([url], ClientMessage::event(event.clone()))
        .await
        .expect("the event goes out");
}

fn socket_of(plane: &SimRelay) -> String {
    plane.url().trim_start_matches("ws://").to_string()
}

// ---------------------------------------------------------------------------
// Bounded reads. Never a sleep: every wait below ends the moment its condition
// holds, and reports what it waited for when it does not.
// ---------------------------------------------------------------------------

/// Polls `read` until it reaches `wanted`, returning what it last read.
async fn reaching(bound: Duration, wanted: usize, read: impl Fn() -> usize + Send + Sync) -> usize {
    let read = &read;
    let _ = poll_until(bound, POLL_EVERY, || async move { Ok(read() >= wanted) })
        .await
        .expect("a ledger read cannot fail");
    read()
}

async fn stored_within(plane: &SimRelay, event_id: &EventId, bound: Duration) -> bool {
    let event_id = *event_id;
    poll_until(bound, POLL_EVERY, || async move {
        plane.stored(&event_id).await
    })
    .await
    .expect("the store reads")
    .is_some()
}

async fn acked_within(plane: &SimRelay, event_id: &EventId, bound: Duration) -> bool {
    let event_id = *event_id;
    poll_until(bound, POLL_EVERY, || async move {
        Ok(plane.witnessed_ok(&event_id))
    })
    .await
    .expect("the ledger reads")
    .is_some()
}

/// The first relay message `accept` takes, inside `bound`.
async fn message_within(
    notifications: &mut broadcast::Receiver<RelayPoolNotification>,
    bound: Duration,
    accept: impl Fn(&RelayMessage<'static>) -> bool + Send + Sync,
) -> Option<RelayMessage<'static>> {
    tokio::time::timeout(bound, async {
        loop {
            match notifications.recv().await {
                Ok(RelayPoolNotification::Message { message, .. }) => {
                    if accept(&message) {
                        return Some(message);
                    }
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    })
    .await
    .ok()
    .flatten()
}

/// The events delivered for `subscription`, in arrival order, up to its `EOSE`,
/// named by the plane's own handles.
///
/// Handles rather than ids deliberately: an assertion's operands are values the
/// test transcript can render, and that transcript is one of the run's own
/// scanned sinks — an event id is an event id whether it reached it from the
/// subject or from an assertion about the subject.
async fn page_within(
    notifications: &mut broadcast::Receiver<RelayPoolNotification>,
    bound: Duration,
    subscription: &SubscriptionId,
    ledger: &Ledger,
) -> Vec<EventTag> {
    let mut page = Vec::new();
    let _ = tokio::time::timeout(bound, async {
        loop {
            match notifications.recv().await {
                Ok(RelayPoolNotification::Message { message, .. }) => match message {
                    RelayMessage::Event {
                        subscription_id,
                        event,
                    } if subscription_id.as_ref() == subscription => page.push(event.id),
                    RelayMessage::EndOfStoredEvents(id) if id.as_ref() == subscription => return,
                    _ => {}
                },
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    })
    .await;
    page.into_iter()
        .map(|id| {
            ledger
                .tag_of(&id)
                .expect("the ledger names every event it delivered")
        })
        .collect()
}

/// Both subscriptions' pages from ONE notification stream, up to each one's own
/// `EOSE`.
///
/// One pass, because two sequential readers would let the first consume frames
/// belonging to the second — and because the interleaving this exists to
/// observe is exactly two pages arriving down one socket at once.
async fn two_pages(
    notifications: &mut broadcast::Receiver<RelayPoolNotification>,
    bound: Duration,
    first: &SubscriptionId,
    second: &SubscriptionId,
    ledger: &Ledger,
) -> (Vec<EventTag>, Vec<EventTag>) {
    let mut pages: (Vec<EventId>, Vec<EventId>) = (Vec::new(), Vec::new());
    let mut ended = (false, false);
    let _ = tokio::time::timeout(bound, async {
        loop {
            match notifications.recv().await {
                Ok(RelayPoolNotification::Message { message, .. }) => match message {
                    RelayMessage::Event {
                        subscription_id,
                        event,
                    } => {
                        if subscription_id.as_ref() == first {
                            pages.0.push(event.id);
                        } else if subscription_id.as_ref() == second {
                            pages.1.push(event.id);
                        }
                    }
                    RelayMessage::EndOfStoredEvents(id) => {
                        if id.as_ref() == first {
                            ended.0 = true;
                        } else if id.as_ref() == second {
                            ended.1 = true;
                        }
                        if ended.0 && ended.1 {
                            return;
                        }
                    }
                    _ => {}
                },
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    })
    .await;
    let named = |ids: Vec<EventId>| -> Vec<EventTag> {
        ids.into_iter()
            .map(|id| {
                ledger
                    .tag_of(&id)
                    .expect("the ledger names every event it delivered")
            })
            .collect()
    };
    (named(pages.0), named(pages.1))
}

// ---------------------------------------------------------------------------
// The healthy plane, which is every other case's control
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_healthy_plane_carries_the_relays_acknowledgement_to_the_client() {
    let plane = plane().await;
    let client = connected_client(&plane).await;

    let event = an_event("the baseline");
    publish(&client, &plane, &event).await;

    assert!(
        acked_within(&plane, &event.id, WIRE_BOUND).await,
        "a healthy plane must carry the relay's OK to the client"
    );
    assert!(
        plane.stored(&event.id).await.expect("the store reads"),
        "an acknowledged event must be in the store the ack came from"
    );
    assert!(
        plane.ledger().published(&event.id) == 1,
        "the ledger must have seen the publish it acked"
    );
}

// ---------------------------------------------------------------------------
// SwallowOk — the Rule-13 fault
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_swallowed_ok_leaves_the_event_stored_and_the_client_none_the_wiser() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    plane
        .apply(Fault::SwallowOk)
        .await
        .expect("the fault applies");

    let event = an_event("stored, never acked");
    publish(&client, &plane, &event).await;

    assert!(
        stored_within(&plane, &event.id, WIRE_BOUND).await,
        "the relay must really hold the event: a fault that lost it would be an outage, not a swallowed ack"
    );
    assert!(
        !acked_within(&plane, &event.id, WIRE_BOUND).await,
        "the acknowledgement must never reach the client"
    );

    // The stored half, proven the way an oracle proves it: a second connection
    // asks the relay for the event and gets it.
    let reader = connected_client(&plane).await;
    let read_back = reader
        .fetch_events(Filter::new().id(event.id), WIRE_BOUND)
        .await
        .expect("the read-back runs");
    assert!(
        read_back.len() == 1,
        "the relay must serve back the event whose ack it swallowed"
    );

    // Negative control: healing restores the acknowledgement path.
    plane.apply(Fault::Heal).await.expect("the heal applies");
    let healed = an_event("acked again");
    publish(&client, &plane, &healed).await;
    assert!(
        acked_within(&plane, &healed.id, WIRE_BOUND).await,
        "a healed plane must acknowledge again, or the fault proved nothing"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_caller_that_needs_an_ack_cannot_get_one_out_of_a_swallowing_plane() {
    // The S-F1 invariant, from the caller's side: `witnessed_ok` is the only
    // predicate the rig has for Rule 13, so if it can never hold under this
    // fault, `confirm_published` is unreachable and a caller must roll back.
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    plane
        .apply(Fault::SwallowOk)
        .await
        .expect("the fault applies");

    let staged: Vec<Event> = (0..3).map(|n| an_event(&format!("staged {n}"))).collect();
    for event in &staged {
        publish(&client, &plane, event).await;
    }
    for event in &staged {
        assert!(
            stored_within(&plane, &event.id, WIRE_BOUND).await,
            "the relay must hold every staged event"
        );
    }
    assert!(
        staged.iter().all(|event| !plane.witnessed_ok(&event.id)),
        "no staged event may be confirmable while the plane swallows acks"
    );

    plane.apply(Fault::Heal).await.expect("the heal applies");
    let confirmable = an_event("confirmable");
    publish(&client, &plane, &confirmable).await;
    assert!(
        acked_within(&plane, &confirmable.id, WIRE_BOUND).await,
        "the same predicate must hold once the plane is healthy, or it is not a predicate"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_location_takes_the_products_location_ladder_and_a_commit_takes_the_commit_one() {
    // The rig measures O1 on whatever ladder it publishes down, so the ladder
    // has to be the product's: `publish_location_event` is ONE bounded attempt
    // (a location is superseded by the next tick, so a retry re-sends a stale
    // position) and `publish_event` is the retrying one a commit needs
    // (Security Rule 13). With the acknowledgement withheld both run to
    // exhaustion, and the frames the plane counted are what tells them apart.
    install_process_globals().expect("the ws:// loopback opt-in installs");
    let mut plane = plane().await;
    plane
        .apply(Fault::SwallowOk)
        .await
        .expect("the fault applies");
    let device = SimDevice::open(DeviceTag::new(0), &[plane.url().to_string()])
        .expect("a device opens its store");

    let location = an_application_445();
    assert!(
        publish_witnessed(
            &device,
            std::slice::from_ref(&plane),
            std::slice::from_ref(&location)
        )
        .await
        .expect("the witness reads")
        .is_none(),
        "the plane acknowledged a publish it was told to swallow, so neither ladder ran out"
    );
    assert!(
        plane.ledger().published(&location.id) == 1,
        "a location went out more than once: the rig published it down the COMMIT ladder, and \
         every O1 measurement would then be of a publish path the product does not have"
    );

    let commit = a_commit_445();
    assert!(
        publish_witnessed(
            &device,
            std::slice::from_ref(&plane),
            std::slice::from_ref(&commit)
        )
        .await
        .expect("the witness reads")
        .is_none(),
        "the plane acknowledged the commit publish, so its ladder did not run out either"
    );
    assert!(
        plane.ledger().published(&commit.id) > 1,
        "a commit went out once: the rig published it down the LOCATION ladder, and Rule 13's \
         retry budget is what buys back a commit nothing re-sends"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn create_under_swallowed_ok_does_not_advance() {
    // Rig invariant R13, against the real proxy rather than against a double
    // that models the fault: a create whose welcome the relay STORED but never
    // acknowledged must be rolled back, and the two halves of that sentence are
    // read from two different places — the rig's verdict, and the plane's own
    // store and ledger.
    install_process_globals().expect("the ws:// loopback opt-in installs");
    let mut plane = plane().await;
    plane
        .apply(Fault::SwallowOk)
        .await
        .expect("the fault applies");

    let urls = vec![plane.url().to_string()];
    let devices = vec![
        SimDevice::open(DeviceTag::new(0), &urls).expect("the admin opens its store"),
        SimDevice::open(DeviceTag::new(1), &urls).expect("the invitee opens its store"),
    ];
    let outstanding = Arc::new(AtomicUsize::new(0));

    let outcome = build_circle(
        CircleTag::new(0),
        &devices,
        std::slice::from_ref(&plane),
        &urls,
        &outstanding,
    )
    .await;

    assert!(
        matches!(outcome, Err(RigError::WelcomeNeverAcked)),
        "a create confirmed without a witnessed ack merges an unpublished commit"
    );
    assert!(
        outstanding.load(std::sync::atomic::Ordering::Acquire) == 0,
        "the refused create left its staged commit counted for ever"
    );

    // The other half, which is what makes this the SwallowOk case rather than
    // an outage: the relay really has the welcomes, and the client was never
    // told so.
    let published = plane.ledger().published_ids();
    assert!(
        !published.is_empty(),
        "no welcome ever reached the relay, so nothing here is about a swallowed ack"
    );
    for event_id in &published {
        assert!(
            plane.stored(event_id).await.expect("the store reads"),
            "the relay did not keep a welcome it was sent: that is an outage, not a swallowed ack"
        );
        assert!(
            !plane.witnessed_ok(event_id),
            "an acknowledgement reached the client, so the create had every right to confirm"
        );
    }

    // And the invitee never joined: a create that was rolled back leaves no
    // peer holding a group the admin does not have.
    assert!(
        devices[1]
            .manager()
            .expect("the invitee's manager")
            .get_circles()
            .await
            .expect("the invitee's circles read")
            .is_empty(),
        "the invitee joined a circle whose create was rolled back"
    );
}

// ---------------------------------------------------------------------------
// Closed — the prefixes the engine reads
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_forged_closed_is_byte_identical_to_the_one_the_relay_sends_itself() {
    for native in [NativeClosed::RateLimited, NativeClosed::AuthRequired] {
        let control = SimRelay::start_refusing_natively(RelayTag::new(0), native)
            .await
            .expect("the control plane starts");
        let watcher = connected_client(&control).await;
        watcher
            .subscribe_with_id(SubscriptionId::new("probe"), Filter::new(), None)
            .await
            .expect("the REQ goes out");
        let native_messages = {
            let ledger = control.ledger().clone();
            reaching(WIRE_BOUND, 1, || ledger.closed_messages().len()).await;
            ledger.closed_messages()
        };

        let mut forged = plane().await;
        forged
            .apply(Fault::Closed(native.prefix()))
            .await
            .expect("the fault applies");
        let client = connected_client(&forged).await;
        client
            .subscribe_with_id(SubscriptionId::new("probe"), Filter::new(), None)
            .await
            .expect("the REQ goes out");
        let forged_messages = {
            let ledger = forged.ledger().clone();
            reaching(WIRE_BOUND, 1, || ledger.closed_messages().len()).await;
            ledger.closed_messages()
        };

        assert!(
            forged_messages.first() == native_messages.first(),
            "a forged CLOSED must be the bytes a relay really sends, or a scenario \
             asserting the engine's reaction to a prefix is asserting the harness's spelling"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_closed_prefix_reaches_the_client_and_its_req_never_reaches_the_relay() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;

    let seeded = an_event("a page the client must not get");
    publish(&client, &plane, &seeded).await;
    assert!(stored_within(&plane, &seeded.id, WIRE_BOUND).await);

    for (n, prefix) in ClosedPrefix::ALL.into_iter().enumerate() {
        plane
            .apply(Fault::Closed(prefix))
            .await
            .expect("the fault applies");
        let subscription = SubscriptionId::new(format!("probe-{n}"));
        client
            .subscribe_with_id(subscription.clone(), Filter::new(), None)
            .await
            .expect("the REQ goes out");

        let ledger = plane.ledger().clone();
        assert!(
            reaching(WIRE_BOUND, n + 1, || ledger.closed_messages().len()).await == n + 1,
            "each refused subscription must produce exactly one CLOSED"
        );
        let delivered = ledger.closed_messages();
        assert!(
            delivered[n].starts_with(prefix.as_str()),
            "a CLOSED must carry the machine-readable prefix the fault named"
        );
        assert!(
            ledger.reqs_for(&subscription) == 1,
            "the client must have issued exactly one REQ for this key"
        );
    }

    assert!(
        plane.ledger().delivered(&seeded.id) == 0,
        "a refused REQ must never reach the relay: a plane that both served the \
         page and closed the subscription would let a scenario pass on the page"
    );

    // Negative control: the same client, the same relay, healed.
    plane.apply(Fault::Heal).await.expect("the heal applies");
    let served = SubscriptionId::new("healed");
    client
        .subscribe_with_id(served.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    assert!(
        reaching(WIRE_BOUND, 1, || ledger.delivered(&seeded.id)).await == 1,
        "a healed plane must serve the page it was refusing"
    );
    assert!(
        ledger.closed_messages().len() == ClosedPrefix::ALL.len(),
        "a healed plane must close nothing"
    );
}

// ---------------------------------------------------------------------------
// Notice
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_notice_reaches_a_live_client_with_the_text_the_schedule_named() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let mut notifications = client.notifications();

    plane
        .apply(Fault::Notice(NOTICE_TEXT))
        .await
        .expect("the fault applies");

    let notice = message_within(&mut notifications, WIRE_BOUND, |message| {
        matches!(message, RelayMessage::Notice(_))
    })
    .await;
    match notice {
        Some(RelayMessage::Notice(held)) => assert!(
            held.as_ref() == NOTICE_TEXT,
            "the NOTICE must carry the text the schedule named"
        ),
        _ => panic!("the client must receive the NOTICE the schedule named"),
    }
    assert!(
        plane.ledger().notices() == vec![NOTICE_TEXT.to_string()],
        "the ledger must hold the one NOTICE that went out"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_notice_nobody_could_receive_is_reported_as_a_fault_that_did_not_fire() {
    let mut plane = plane().await;
    assert!(
        plane.apply(Fault::Notice(NOTICE_TEXT)).await.is_err(),
        "a notice with no live connection did not happen, and a bound derived \
         from it would be a fiction"
    );
    assert!(plane.ledger().notices().is_empty());
}

// ---------------------------------------------------------------------------
// DoubleEveryEvent
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doubling_plane_puts_two_event_frames_on_the_wire_for_one_stored_event() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;

    let event = an_event("delivered twice");
    publish(&client, &plane, &event).await;
    assert!(stored_within(&plane, &event.id, WIRE_BOUND).await);

    plane
        .apply(Fault::DoubleEveryEvent)
        .await
        .expect("the fault applies");
    let mut notifications = client.notifications();
    let doubled = SubscriptionId::new("doubled");
    client
        .subscribe_with_id(doubled.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");

    let ledger = plane.ledger().clone();
    assert!(
        reaching(WIRE_BOUND, 2, || ledger.delivered(&event.id)).await == 2,
        "one stored event must leave as two EVENT frames"
    );
    let delivered_twice = ledger
        .tag_of(&event.id)
        .expect("the ledger names what it delivered");
    assert!(
        page_within(&mut notifications, WIRE_BOUND, &doubled, &ledger).await
            == vec![delivered_twice, delivered_twice],
        "the client must really receive both frames, not just the proxy write them"
    );

    // Negative control: healed, the next page carries it once.
    plane.apply(Fault::Heal).await.expect("the heal applies");
    client
        .subscribe_with_id(SubscriptionId::new("healed"), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    assert!(
        reaching(WIRE_BOUND, 3, || ledger.delivered(&event.id)).await == 3,
        "a healed plane must deliver one frame per stored event"
    );
}

// ---------------------------------------------------------------------------
// ReversePages
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reversing_plane_delivers_the_relays_own_page_backwards() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;

    let page: Vec<Event> = (0..3)
        .map(|n| an_event_at(&format!("page entry {n}"), 30 - n))
        .collect();
    for event in &page {
        publish(&client, &plane, event).await;
        assert!(stored_within(&plane, &event.id, WIRE_BOUND).await);
    }

    let mut notifications = client.notifications();
    let straight = SubscriptionId::new("straight");
    client
        .subscribe_with_id(straight.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    let forward = page_within(&mut notifications, WIRE_BOUND, &straight, &ledger).await;
    assert!(
        forward.len() == 3,
        "the healthy page must carry every event"
    );

    plane
        .apply(Fault::ReversePages)
        .await
        .expect("the fault applies");
    let reversed_id = SubscriptionId::new("reversed");
    client
        .subscribe_with_id(reversed_id.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let reversed = page_within(&mut notifications, WIRE_BOUND, &reversed_id, &ledger).await;

    let mut backwards = forward.clone();
    backwards.reverse();
    assert!(
        reversed == backwards,
        "the same relay, the same page, the opposite order"
    );
    assert!(
        reversed != forward,
        "a page of one event would make this vacuous"
    );

    // Negative control: healed, the relay's own order survives again.
    plane.apply(Fault::Heal).await.expect("the heal applies");
    let healed_id = SubscriptionId::new("healed");
    client
        .subscribe_with_id(healed_id.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    assert!(
        page_within(&mut notifications, WIRE_BOUND, &healed_id, &ledger).await == forward,
        "a healed plane must serve the relay's own order again"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_subscriptions_on_one_socket_each_get_their_own_page_reversed() {
    // The shape a device really produces: one pooled socket carrying several
    // REQs at once. A page held back per CONNECTION is released by whichever
    // `EOSE` arrives first — so one subscription's page comes back in the
    // relay's own order, with the rest of it still to come, and a scenario
    // asserting a reversal passes or fails on the scheduling.
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let one = Keys::generate();
    let other = Keys::generate();
    // Three and two: a page of one event cannot show a reversal, and two
    // lengths tell the pages apart even if the ids did not.
    let first_page: Vec<Event> = (0..3)
        .map(|n| a_note_by(&one, &format!("first {n}"), 30 - n))
        .collect();
    let second_page: Vec<Event> = (0..2)
        .map(|n| a_note_by(&other, &format!("second {n}"), 20 - n))
        .collect();
    for event in first_page.iter().chain(second_page.iter()) {
        publish(&client, &plane, event).await;
        assert!(stored_within(&plane, &event.id, WIRE_BOUND).await);
    }

    let ledger = plane.ledger().clone();
    let mut notifications = client.notifications();
    let (straight_first, straight_second) = (
        SubscriptionId::new("straight-first"),
        SubscriptionId::new("straight-second"),
    );
    for (id, keys) in [(&straight_first, &one), (&straight_second, &other)] {
        client
            .subscribe_with_id(id.clone(), Filter::new().author(keys.public_key()), None)
            .await
            .expect("the REQ goes out");
    }
    let (forward_first, forward_second) = two_pages(
        &mut notifications,
        WIRE_BOUND,
        &straight_first,
        &straight_second,
        &ledger,
    )
    .await;
    assert!(
        forward_first.len() == first_page.len() && forward_second.len() == second_page.len(),
        "the healthy pages must carry every event, or a reversal below proves nothing"
    );

    plane
        .apply(Fault::ReversePages)
        .await
        .expect("the fault applies");
    let (reversed_first, reversed_second) = (
        SubscriptionId::new("reversed-first"),
        SubscriptionId::new("reversed-second"),
    );
    for (id, keys) in [(&reversed_first, &one), (&reversed_second, &other)] {
        client
            .subscribe_with_id(id.clone(), Filter::new().author(keys.public_key()), None)
            .await
            .expect("the REQ goes out");
    }
    let (backwards_first, backwards_second) = two_pages(
        &mut notifications,
        WIRE_BOUND,
        &reversed_first,
        &reversed_second,
        &ledger,
    )
    .await;

    let mut wanted_first = forward_first.clone();
    wanted_first.reverse();
    let mut wanted_second = forward_second.clone();
    wanted_second.reverse();
    assert!(
        backwards_first == wanted_first,
        "the first subscription got a page that is not its own, reversed"
    );
    assert!(
        backwards_second == wanted_second,
        "the second subscription got a page that is not its own, reversed"
    );
}

// ---------------------------------------------------------------------------
// EoseForAnotherSubscription
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cross_subscription_eose_arrives_beside_the_clients_own() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    plane
        .apply(Fault::EoseForAnotherSubscription)
        .await
        .expect("the fault applies");

    let mut notifications = client.notifications();
    let mine = SubscriptionId::new("mine");
    client
        .subscribe_with_id(mine.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");

    let stranger = message_within(
        &mut notifications,
        WIRE_BOUND,
        |message| matches!(message, RelayMessage::EndOfStoredEvents(id) if id.as_ref() != &mine),
    )
    .await;
    assert!(
        stranger.is_some(),
        "an EOSE naming a subscription this client never opened must reach it"
    );
    assert!(
        message_within(&mut notifications, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::EndOfStoredEvents(id) if id.as_ref() == &mine)
        })
        .await
        .is_some(),
        "the client's own EOSE must still arrive: a lost one is a different fault"
    );

    // Negative control: healed, a subscription gets exactly its own EOSE.
    plane.apply(Fault::Heal).await.expect("the heal applies");
    let ledger = plane.ledger().clone();
    let before = ledger.eose();
    let healed = SubscriptionId::new("healed");
    client
        .subscribe_with_id(healed.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    assert!(
        reaching(WIRE_BOUND, before + 1, || ledger.eose()).await == before + 1,
        "a healed plane must send one EOSE per subscription"
    );
}

// ---------------------------------------------------------------------------
// Down / Up
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plane_that_goes_down_refuses_connections_and_comes_back_on_the_same_address() {
    let mut plane = plane().await;
    let socket = socket_of(&plane);
    let address = plane.url().to_string();
    let mut lingering = TcpStream::connect(&socket)
        .await
        .expect("a healthy plane accepts");

    plane.apply(Fault::Down).await.expect("the fault applies");

    // Not a race: taking the plane down awaits the accept task, so the listener
    // is released before the call returns.
    assert!(
        TcpStream::connect(&socket).await.is_err(),
        "a down plane must refuse the connection, not accept it and fail behind the curtain"
    );
    let mut byte = [0u8; 1];
    let lingered = tokio::time::timeout(WIRE_BOUND, lingering.read(&mut byte)).await;
    assert!(
        matches!(lingered, Ok(Ok(0) | Err(_))),
        "a connection that was live when the plane went down must not survive it"
    );

    plane.apply(Fault::Up).await.expect("the plane comes back");
    assert!(
        plane.url() == address,
        "a plane must heal onto its own address"
    );
    let (attempts, _waited) = plane.ledger().rebind();
    assert!(
        attempts >= 1,
        "the rebind must be recorded: what it cost is the measurement"
    );
    assert!(
        TcpStream::connect(&socket).await.is_ok(),
        "the same address must accept again"
    );

    // The socket is not the service: a client must be able to publish again.
    let client = connected_client(&plane).await;
    let event = an_event("after the outage");
    publish(&client, &plane, &event).await;
    assert!(acked_within(&plane, &event.id, WIRE_BOUND).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healing_a_down_plane_brings_its_endpoint_back() {
    let mut plane = plane().await;
    let socket = socket_of(&plane);
    plane.apply(Fault::Down).await.expect("the fault applies");
    assert!(TcpStream::connect(&socket).await.is_err());

    plane.apply(Fault::Heal).await.expect("the heal applies");
    assert!(
        TcpStream::connect(&socket).await.is_ok(),
        "a heal must undo an outage, or a schedule that heals proves nothing about recovery"
    );
}

// ---------------------------------------------------------------------------
// WipeStore
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wiped_plane_forgets_what_it_held_and_keeps_serving() {
    let mut plane = plane().await;
    let address = plane.url().to_string();
    let client = connected_client(&plane).await;

    let forgotten = an_event("held, then forgotten");
    publish(&client, &plane, &forgotten).await;
    assert!(stored_within(&plane, &forgotten.id, WIRE_BOUND).await);

    plane
        .apply(Fault::WipeStore)
        .await
        .expect("the fault applies");

    assert!(
        !plane.stored(&forgotten.id).await.expect("the store reads"),
        "a wiped store must not hold what it held"
    );
    assert!(
        plane.url() == address,
        "forgetting is not an outage: the address must not move"
    );

    let after = an_event("after the wipe");
    publish(&client, &plane, &after).await;
    assert!(
        acked_within(&plane, &after.id, WIRE_BOUND).await,
        "a wiped plane must keep accepting: the store forgot, the relay did not stop"
    );
}

// ---------------------------------------------------------------------------
// Inject: a forged event on the wire and in nobody's store
// ---------------------------------------------------------------------------

/// A subscription that takes everything, so a forgery's delivery turns on the
/// FAULT and not on a filter this test wrote.
async fn subscribed_to_everything(client: &Client, plane: &SimRelay, id: &str) -> SubscriptionId {
    let subscription = SubscriptionId::new(id);
    client
        .subscribe_with_id(subscription.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    // The REQ must have CROSSED the proxy before an injection asks which
    // subscriptions are open: a race here would refuse a fault that is about
    // to be perfectly deliverable.
    let ledger = plane.ledger().clone();
    reaching(WIRE_BOUND, 1, move || ledger.reqs()).await;
    subscription
}

/// The event the plane injected, once it has injected one.
async fn injected_within(plane: &SimRelay, bound: Duration) -> EventId {
    let ledger = plane.ledger().clone();
    reaching(bound, 1, move || ledger.injected_ids().len()).await;
    *plane
        .ledger()
        .injected_ids()
        .first()
        .expect("the plane records what it forged")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injected_rewrap_carries_the_observed_ciphertext_and_no_store_holds_it() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let subscription = subscribed_to_everything(&client, &plane, "watching").await;
    let mut notifications = client.notifications();

    let observed = an_application_445();
    publish(&client, &plane, &observed).await;
    assert!(stored_within(&plane, &observed.id, WIRE_BOUND).await);

    plane
        .apply(Fault::Inject(Forgery::Rewrap {
            source: observed.id,
            offset_secs: 3600,
        }))
        .await
        .expect("the injection applies");

    let forged = message_within(&mut notifications, WIRE_BOUND, |message| {
        matches!(message, RelayMessage::Event { subscription_id, event }
            if subscription_id.as_ref() == &subscription && event.id != observed.id)
    })
    .await
    .expect("the forged event reaches a subscribed client");
    let RelayMessage::Event { event: forged, .. } = forged else {
        unreachable!("the predicate above accepted only an EVENT")
    };

    assert!(
        forged.content == observed.content,
        "a rewrap copies the ciphertext it observed"
    );
    assert!(
        forged.pubkey != observed.pubkey,
        "a rewrap is signed by somebody who holds no MLS secret"
    );
    assert!(
        !plane.stored(&forged.id).await.expect("the store reads"),
        "an injection is in flight and never retained: a later page must not serve it"
    );
    assert!(
        plane.ledger().published(&forged.id) == 0,
        "nobody published it; the plane forged it"
    );
    assert!(
        plane.ledger().injected_ids() == vec![forged.id],
        "the plane records what it forged, so a scenario can name it without minting it"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injected_malformed_double_h_reaches_the_client_and_no_store_holds_it() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let subscription = subscribed_to_everything(&client, &plane, "watching").await;
    let mut notifications = client.notifications();

    plane
        .apply(Fault::Inject(Forgery::MalformedDoubleH {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await
        .expect("the injection applies");

    let message = message_within(&mut notifications, WIRE_BOUND, |message| {
        matches!(message, RelayMessage::Event { subscription_id, .. }
            if subscription_id.as_ref() == &subscription)
    })
    .await
    .expect("the forged event reaches a subscribed client");
    let RelayMessage::Event { event, .. } = message else {
        unreachable!("the predicate above accepted only an EVENT")
    };

    assert!(
        event
            .tags
            .iter()
            .filter(|tag| tag.kind().as_str() == "h")
            .count()
            == 2,
        "the doubled routing tag is what Haven's pre-engine parse refuses"
    );
    assert!(
        !plane.stored(&event.id).await.expect("the store reads"),
        "an injection is never retained"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injected_unprocessable_forgery_reaches_the_client_and_no_store_holds_it() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let subscription = subscribed_to_everything(&client, &plane, "watching").await;
    let mut notifications = client.notifications();

    plane
        .apply(Fault::Inject(Forgery::Unprocessable {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await
        .expect("the injection applies");

    let message = message_within(&mut notifications, WIRE_BOUND, |message| {
        matches!(message, RelayMessage::Event { subscription_id, .. }
            if subscription_id.as_ref() == &subscription)
    })
    .await
    .expect("the forged event reaches a subscribed client");
    let RelayMessage::Event { event, .. } = message else {
        unreachable!("the predicate above accepted only an EVENT")
    };

    assert!(
        event
            .tags
            .iter()
            .filter(|tag| tag.kind().as_str() == "h")
            .count()
            == 1,
        "one routing tag: this one parses, and the ENGINE is what refuses it"
    );
    assert!(
        !plane.stored(&event.id).await.expect("the store reads"),
        "an injection is never retained"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injected_expired_forgery_goes_out_on_the_wire_and_no_store_holds_it() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let _subscription = subscribed_to_everything(&client, &plane, "watching").await;

    plane
        .apply(Fault::Inject(Forgery::Expired {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await
        .expect("the injection applies");

    // The WIRE is the evidence here, not the client: a conformant SDK drops an
    // already-expired event before it ever emits a notification, which is the
    // whole reason this forgery can only be injected — the relay's own store
    // refuses to hold it and its queries filter it out.
    let forged = injected_within(&plane, WIRE_BOUND).await;
    let ledger = plane.ledger().clone();
    assert!(
        reaching(WIRE_BOUND, 1, move || ledger.delivered(&forged)).await >= 1,
        "the forged frame must really have been written towards the client"
    );
    assert!(
        !plane.stored(&forged).await.expect("the store reads"),
        "an expired event is one no relay would retain, which is why it is injected"
    );
    assert!(
        !plane.witnessed_ok(&forged),
        "nobody published it, so nothing acknowledged it"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injection_nobody_subscribed_for_is_reported_as_a_fault_that_did_not_fire() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;

    // Connected, but listening for something else entirely.
    let subscription = SubscriptionId::new("wants-profiles");
    client
        .subscribe_with_id(subscription, Filter::new().kind(Kind::Metadata), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    reaching(WIRE_BOUND, 1, move || ledger.reqs()).await;

    let refused = plane
        .apply(Fault::Inject(Forgery::Unprocessable {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await;
    assert!(
        matches!(refused, Err(RigError::Core(_))),
        "an injection nobody received did not happen, and a bound derived from it is a fiction"
    );
    assert!(
        plane.ledger().injected_ids().is_empty(),
        "a fault that did not fire records nothing"
    );
    assert!(
        plane.faults_applied() == 0,
        "and it must not be counted towards an arm's expectation floor"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rewrap_of_an_event_this_plane_never_carried_is_refused() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let _subscription = subscribed_to_everything(&client, &plane, "watching").await;

    let never_published = an_application_445();
    let refused = plane
        .apply(Fault::Inject(Forgery::Rewrap {
            source: never_published.id,
            offset_secs: 60,
        }))
        .await;
    assert!(
        matches!(refused, Err(RigError::Core(_))),
        "an OBSERVED ciphertext means one this relay really carried; a copy of nothing is \
         a synthetic shape the arm did not ask for"
    );
}

// ---------------------------------------------------------------------------
// RefuseOversize: the rig's first forged `OK false`
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_oversize_event_is_refused_machine_readably_and_a_smaller_one_is_not() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;

    let refused = an_event("this one is over the cap");
    plane
        .apply(Fault::RefuseOversize {
            max_bytes: ByteCap::new(refused.as_json().len() - 1),
        })
        .await
        .expect("the cap applies");
    publish(&client, &plane, &refused).await;

    let ledger = plane.ledger().clone();
    let id = refused.id;
    reaching(WIRE_BOUND, 1, move || {
        usize::from(ledger.refusal(&id).is_some())
    })
    .await;
    let message = plane
        .ledger()
        .refusal(&refused.id)
        .expect("the client was told why");
    assert!(
        message.starts_with(OVERSIZE_PREFIX.as_str()),
        "a client branches on the machine-readable prefix"
    );
    assert!(
        !plane.stored(&refused.id).await.expect("the store reads"),
        "a refused event must not be in the store: a plane that stored it and said no would \
         let an arm pass on the store"
    );
    assert!(
        !plane.witnessed_ok(&refused.id),
        "a refusal is not an acknowledgement (Rule 13)"
    );

    // The matched pair: the same plane, the same client, one byte of cap the
    // other way. Without it the arm would pass on a plane that refuses
    // everything.
    let accepted = an_event("this one is under the cap");
    plane
        .apply(Fault::RefuseOversize {
            max_bytes: ByteCap::new(accepted.as_json().len() + 1),
        })
        .await
        .expect("the cap applies");
    publish(&client, &plane, &accepted).await;
    assert!(
        acked_within(&plane, &accepted.id, WIRE_BOUND).await,
        "an event inside the cap is carried and acknowledged as it always was"
    );
    assert!(
        plane.stored(&accepted.id).await.expect("the store reads"),
        "and stored"
    );
    assert!(
        plane.ledger().refusal(&accepted.id).is_none(),
        "and never refused"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_forged_refusal_has_the_shape_the_relays_own_refusal_has() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;

    // The control is the relay's OWN refusal: an event whose signature does not
    // verify, which `nostr-relay-builder` refuses with `invalid: …` of its own
    // composition. A forged frame is only worth what its shape is.
    let corrupted = corrupt_the_signature_of(&an_event("this signature is not mine"));
    publish(&client, &plane, &corrupted).await;
    let ledger = plane.ledger().clone();
    let id = corrupted.id;
    reaching(WIRE_BOUND, 1, move || {
        usize::from(ledger.refusal(&id).is_some())
    })
    .await;
    let native = plane
        .ledger()
        .refusal(&corrupted.id)
        .expect("the relay refuses an unverifiable event");

    let forged_at = an_event("this one is over the cap");
    plane
        .apply(Fault::RefuseOversize {
            max_bytes: ByteCap::new(forged_at.as_json().len() - 1),
        })
        .await
        .expect("the cap applies");
    publish(&client, &plane, &forged_at).await;
    let ledger = plane.ledger().clone();
    let id = forged_at.id;
    reaching(WIRE_BOUND, 1, move || {
        usize::from(ledger.refusal(&id).is_some())
    })
    .await;
    let forged = plane
        .ledger()
        .refusal(&forged_at.id)
        .expect("the forged refusal reaches the client");

    let prefix_of = |message: &str| {
        nostr::message::MachineReadablePrefix::parse(message)
            .map(|prefix| prefix.as_str().to_owned())
    };
    assert!(
        prefix_of(&native) == prefix_of(&forged),
        "the forged refusal must parse to the prefix a real one does, or an engine reacting \
         to the prefix is reacting to something no relay sends"
    );
    assert!(
        native != forged,
        "the two say different things: the control proves the SHAPE, not the words"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refusal_and_a_swallowed_acknowledgement_are_distinct_in_the_ledger() {
    // S18's whole oracle is the gap between the store and the client-facing
    // ack. This is the proof that the rig's first `OK false` cannot be mistaken
    // for it: both answer `witnessed_ok` with `false` — Rule 13's disposition
    // is identical, which is correct — and the ledger tells them apart.
    let mut swallowing = plane().await;
    let swallow_client = connected_client(&swallowing).await;
    swallowing
        .apply(Fault::SwallowOk)
        .await
        .expect("the fault applies");
    let swallowed = an_event("stored, and the ack never arrives");
    publish(&swallow_client, &swallowing, &swallowed).await;
    assert!(
        stored_within(&swallowing, &swallowed.id, WIRE_BOUND).await,
        "a swallowed OK means the relay HAS it"
    );

    let mut refusing = plane().await;
    let refuse_client = connected_client(&refusing).await;
    let refused = an_event("refused, and never stored");
    refusing
        .apply(Fault::RefuseOversize {
            max_bytes: ByteCap::new(refused.as_json().len() - 1),
        })
        .await
        .expect("the fault applies");
    publish(&refuse_client, &refusing, &refused).await;
    let ledger = refusing.ledger().clone();
    let id = refused.id;
    reaching(WIRE_BOUND, 1, move || {
        usize::from(ledger.refusal(&id).is_some())
    })
    .await;

    assert!(
        !swallowing.witnessed_ok(&swallowed.id) && !refusing.witnessed_ok(&refused.id),
        "neither is acked, which is why the disposition is the same"
    );
    assert!(
        swallowing.ledger().refusal(&swallowed.id).is_none(),
        "a swallowed OK leaves NO frame: recording one would turn S18's silence into a refusal"
    );
    assert!(
        refusing.ledger().refusal(&refused.id).is_some(),
        "a refusal is a frame the client really received"
    );
    assert!(
        swallowing
            .stored(&swallowed.id)
            .await
            .expect("the store reads")
            && !refusing.stored(&refused.id).await.expect("the store reads"),
        "stored-and-silent against refused-and-absent: the two halves that tell them apart"
    );
}

// ---------------------------------------------------------------------------
// Per-device endpoints and DropClass: a partition between the relay and ONE
// device
// ---------------------------------------------------------------------------

/// A plane with an endpoint of its own for each of `devices`.
async fn provisioned_plane(devices: &[DeviceTag]) -> SimRelay {
    let mut plane = plane().await;
    for device in devices {
        plane
            .provision(*device)
            .await
            .expect("a device's endpoint binds");
    }
    plane
}

/// A client dialling `device`'s own endpoint and subscribed to everything on
/// it, with the REQ known to have crossed the proxy.
async fn client_on(plane: &SimRelay, device: DeviceTag, reqs_so_far: usize) -> Client {
    let client = Client::builder().build();
    client.automatic_authentication(false);
    client
        .add_relay(plane.url_for(device))
        .await
        .expect("the client takes the device's own address");
    client.connect().await;
    client.wait_for_connection(WIRE_BOUND).await;
    client
        .subscribe_with_id(SubscriptionId::new("everything"), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    reaching(WIRE_BOUND, reqs_so_far + 1, move || ledger.reqs()).await;
    client
}

/// Waits until `device`'s own endpoint has carried `marker`.
///
/// The frames of one connection are written in order, so a marker published
/// AFTER the event under test, once seen on a device's endpoint, proves that
/// endpoint's answer for the earlier event is final rather than in flight.
async fn marker_reached(plane: &SimRelay, device: DeviceTag, marker: &EventId) -> bool {
    let ledger = plane.ledger().clone();
    let marker = *marker;
    reaching(WIRE_BOUND, 1, move || {
        usize::from(ledger.delivered_to(device, &marker))
    })
    .await
        == 1
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_dropped_class_is_withheld_from_one_devices_endpoint_and_carried_to_the_others() {
    let (alice, bob) = (DeviceTag::new(0), DeviceTag::new(1));
    let mut plane = provisioned_plane(&[alice, bob]).await;
    assert!(
        plane.url_for(alice) != plane.url_for(bob) && plane.url_for(alice) != plane.url(),
        "two devices dial two endpoints, and neither is the canonical one"
    );
    let alices = client_on(&plane, alice, 0).await;
    let bobs = client_on(&plane, bob, 1).await;
    let mut alice_sees = alices.notifications();
    let mut bob_sees = bobs.notifications();

    plane
        .apply_for(alice, Fault::DropClass(DropClass::Application))
        .await
        .expect("the fault applies");

    // The application message first, then the handshake as the marker: on
    // alice's socket the handshake is the positive control AND the proof that
    // the application frame is not merely late — and it is the discriminator's
    // own control, because the two differ only in the expiration tag.
    let location = an_application_445();
    let commit = a_commit_445();
    publish_on(&bobs, plane.url_for(bob), &location).await;
    publish_on(&bobs, plane.url_for(bob), &commit).await;

    assert!(
        message_within(&mut alice_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Event { event, .. } if event.id == commit.id)
        })
        .await
        .is_some(),
        "the handshake-shaped 445 must reach the partitioned device: only the CLASS is dropped"
    );
    assert!(
        !plane.ledger().delivered_to(alice, &location.id),
        "the application 445 was written towards the partitioned device's own socket"
    );
    assert!(
        message_within(&mut bob_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Event { event, .. } if event.id == location.id)
        })
        .await
        .is_some(),
        "the other device's endpoint must carry the application message untouched"
    );
    assert!(
        marker_reached(&plane, bob, &commit.id).await,
        "and the handshake"
    );
    assert!(
        plane.stored(&location.id).await.expect("the store reads")
            && acked_within(&plane, &location.id, WIRE_BOUND).await,
        "the relay stored and acknowledged it: a drop is a partition, never an outage"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healing_one_devices_endpoint_restores_it_and_leaves_the_others_partition_standing() {
    let (alice, bob) = (DeviceTag::new(0), DeviceTag::new(1));
    let mut plane = provisioned_plane(&[alice, bob]).await;
    let alices = client_on(&plane, alice, 0).await;
    let _bobs = client_on(&plane, bob, 1).await;
    let mut alice_sees = alices.notifications();
    for device in [alice, bob] {
        plane
            .apply_for(device, Fault::DropClass(DropClass::Application))
            .await
            .expect("the fault applies");
    }
    plane
        .apply_for(alice, Fault::Heal)
        .await
        .expect("the heal applies");

    let location = an_application_445();
    let commit = a_commit_445();
    publish_on(&alices, plane.url_for(alice), &location).await;
    publish_on(&alices, plane.url_for(alice), &commit).await;

    assert!(
        message_within(&mut alice_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Event { event, .. } if event.id == location.id)
        })
        .await
        .is_some(),
        "a healed endpoint carries the class it was dropping"
    );
    assert!(
        marker_reached(&plane, bob, &commit.id).await,
        "the other device's endpoint is still up and carrying handshakes"
    );
    assert!(
        !plane.ledger().delivered_to(bob, &location.id),
        "and still dropping applications: healing one endpoint disturbed another's fault"
    );
    assert!(
        plane.faults_applied() == 2,
        "two faults were taken and a heal is not a fault, per device as per plane"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_device_with_no_endpoint_dials_the_canonical_one_and_takes_no_fault_of_its_own() {
    let (alice, stranger) = (DeviceTag::new(0), DeviceTag::new(7));
    let mut plane = provisioned_plane(&[alice]).await;
    assert!(
        plane.url_for(stranger) == plane.url(),
        "a device this plane never provisioned dials the canonical endpoint"
    );
    assert!(
        matches!(
            plane
                .apply_for(stranger, Fault::DropClass(DropClass::Handshake))
                .await,
            Err(RigError::UnknownTarget)
        ),
        "a fault aimed at an endpoint nobody dials would count towards a floor while \
         changing nothing any engine sees; it is refused rather than armed on nothing"
    );
    assert!(
        plane.faults_applied() == 0,
        "a refused fault is a fault that did not fire, and is not counted"
    );

    plane
        .apply_for(alice, Fault::DropClass(DropClass::Handshake))
        .await
        .expect("the provisioned device takes its fault");
    assert!(
        plane.faults_applied() == 1,
        "a per-device fault is counted once, against the plane's one ledger"
    );

    // The canonical endpoint is untouched by a device's fault: a client on it
    // still receives the class alice's endpoint is dropping.
    let canonical = connected_client(&plane).await;
    let mut canonical_sees = canonical.notifications();
    canonical
        .subscribe_with_id(SubscriptionId::new("everything"), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    reaching(WIRE_BOUND, 1, move || ledger.reqs()).await;
    let commit = a_commit_445();
    publish(&canonical, &plane, &commit).await;
    assert!(
        message_within(&mut canonical_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Event { event, .. } if event.id == commit.id)
        })
        .await
        .is_some(),
        "the canonical endpoint carries what one device's endpoint is dropping"
    );
    assert!(
        !plane.ledger().delivered_to(alice, &commit.id),
        "no device's own endpoint carried a frame the canonical one delivered"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_delivery_is_answered_per_device_for_one_event_on_one_plane() {
    let (alice, bob, carol) = (DeviceTag::new(0), DeviceTag::new(1), DeviceTag::new(2));
    let mut plane = provisioned_plane(&[alice, bob]).await;
    let alices = client_on(&plane, alice, 0).await;
    let _bobs = client_on(&plane, bob, 1).await;

    let seen_by_both = an_event("carried to both endpoints");
    publish_on(&alices, plane.url_for(alice), &seen_by_both).await;
    assert!(marker_reached(&plane, alice, &seen_by_both.id).await);
    assert!(marker_reached(&plane, bob, &seen_by_both.id).await);
    assert!(
        !plane.ledger().delivered_to(carol, &seen_by_both.id),
        "a device with no endpoint on this plane was sent nothing through one"
    );
    assert!(
        plane.ledger().delivered(&seen_by_both.id) == 2,
        "the plane-wide count is the sum over the endpoints that carried it"
    );

    plane
        .apply_for(bob, Fault::DropClass(DropClass::Application))
        .await
        .expect("the fault applies");
    let location = an_application_445();
    let marker = a_commit_445();
    publish_on(&alices, plane.url_for(alice), &location).await;
    publish_on(&alices, plane.url_for(alice), &marker).await;
    assert!(marker_reached(&plane, alice, &marker.id).await);
    assert!(marker_reached(&plane, bob, &marker.id).await);
    assert!(
        plane.ledger().delivered_to(alice, &location.id)
            && !plane.ledger().delivered_to(bob, &location.id),
        "the same event on the same plane: one endpoint carried it and the other withheld it"
    );
    assert!(
        plane.ledger().delivered(&location.id) == 1,
        "and the plane-wide count says how many endpoints did"
    );
}

/// A plane-wide injection and a plane-wide notice are written on EVERY endpoint
/// with a listener — the canonical one an observer watches AND the device's own
/// one an engine dials — never on the first that answered. A fan-out that
/// stopped there would leave every engine but one unsent, and an arm's
/// "the engine received the forgery" canary would be reading luck.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plane_wide_injection_and_notice_reach_a_devices_own_endpoint_beside_the_canonical() {
    let alice = DeviceTag::new(0);
    let mut plane = provisioned_plane(&[alice]).await;
    let observer = connected_client(&plane).await;
    let observing = subscribed_to_everything(&observer, &plane, "observer").await;
    let alices = client_on(&plane, alice, 1).await;
    let mut observer_sees = observer.notifications();
    let mut alice_sees = alices.notifications();

    plane
        .apply(Fault::Inject(Forgery::OutsiderSeal {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await
        .expect("the injection applies");
    let forged = injected_within(&plane, WIRE_BOUND).await;
    assert!(
        message_within(&mut observer_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Event { subscription_id, event }
                if subscription_id.as_ref() == &observing && event.id == forged)
        })
        .await
        .is_some(),
        "the canonical endpoint carried the injection"
    );
    assert!(
        message_within(&mut alice_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Event { event, .. } if event.id == forged)
        })
        .await
        .is_some(),
        "the DEVICE endpoint — the one an engine dials — carried the injection too"
    );
    let ledger = plane.ledger().clone();
    assert!(
        reaching(WIRE_BOUND, 2, move || ledger.delivered(&forged)).await == 2
            && plane.ledger().delivered_to(alice, &forged),
        "one frame per endpoint, and the ledger answers for the device's own"
    );

    plane
        .apply(Fault::Notice(NOTICE_TEXT))
        .await
        .expect("the notice applies");
    assert!(
        message_within(&mut observer_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Notice(held) if held.as_ref() == NOTICE_TEXT)
        })
        .await
        .is_some(),
        "the canonical endpoint carried the plane-wide notice"
    );
    assert!(
        message_within(&mut alice_sees, WIRE_BOUND, |message| {
            matches!(message, RelayMessage::Notice(held) if held.as_ref() == NOTICE_TEXT)
        })
        .await
        .is_some(),
        "the device's own endpoint carried the plane-wide notice too"
    );
}

/// The same fan-out in a real world: three engines on their own endpoints of
/// one plane, one plane-wide injection, and every device's endpoint carries
/// it — the ledger's per-device answer is true for each, and the plane-wide
/// count is the number of devices.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn in_a_world_a_plane_wide_injection_reaches_every_devices_own_endpoint() {
    install_process_globals().expect("the ws:// loopback opt-in");
    let shape = WorldShape {
        members: 3,
        circles: 1,
        relays: 1,
    };
    let mut world: SimWorld<SimRelay, Timeline, NoDrain> = SimWorld::build(
        &shape,
        Schedule::new(Vec::new()),
        vec![plane().await],
        Timeline::in_memory(),
        NoDrain,
    )
    .await
    .expect("a three-member world builds");
    let routing = *world.circles()[0].nostr_group_id();
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    // Every engine's group REQ has crossed the proxy before the injection is
    // asked, or an endpoint with no subscription yet would be correctly absent.
    let probe =
        mint(Forgery::OutsiderSeal { group_id: routing }, None).expect("a probe forgery mints");
    let ledger = world.relays()[0].ledger().clone();
    reaching(WIRE_BOUND, tags.len(), move || {
        ledger.subscriptions_matching(&probe).len()
    })
    .await;

    world.relays_mut()[0]
        .apply(Fault::Inject(Forgery::OutsiderSeal { group_id: routing }))
        .await
        .expect("the injection applies");
    let forged = injected_within(&world.relays()[0], WIRE_BOUND).await;
    let ledger = world.relays()[0].ledger().clone();
    let delivered = reaching(WIRE_BOUND, tags.len(), move || ledger.delivered(&forged)).await;
    let carried: Vec<bool> = tags
        .iter()
        .map(|tag| world.relays()[0].ledger().delivered_to(*tag, &forged))
        .collect();
    world.teardown().await.expect("teardown");
    assert!(
        carried.iter().all(|carried| *carried),
        "a plane-wide injection must reach every device's own endpoint, not the first with a listener"
    );
    assert!(
        delivered == tags.len(),
        "and the plane-wide count is one frame per device"
    );
}

// ---------------------------------------------------------------------------
// Heal, over everything at once
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_heal_restores_the_pass_through_whatever_was_wrong() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let seeded = an_event("seeded before everything broke");
    publish(&client, &plane, &seeded).await;
    assert!(stored_within(&plane, &seeded.id, WIRE_BOUND).await);

    for fault in [
        Fault::SwallowOk,
        Fault::DoubleEveryEvent,
        Fault::ReversePages,
        Fault::EoseForAnotherSubscription,
        Fault::Closed(ClosedPrefix::RateLimited),
        // One byte of cap: after the heal, a publish that would have been
        // refused has to be carried again.
        Fault::RefuseOversize {
            max_bytes: ByteCap::new(1),
        },
        // A class is a partition of the canonical endpoint too; the last one
        // armed is what a heal must undo, and the page below carries one
        // event of each class to prove it.
        Fault::DropClass(DropClass::Application),
        Fault::DropClass(DropClass::Handshake),
        Fault::Down,
    ] {
        plane.apply(fault).await.expect("the fault applies");
    }
    plane.apply(Fault::Heal).await.expect("the heal applies");

    let healed_client = connected_client(&plane).await;
    let mut notifications = healed_client.notifications();
    let event = an_event("after the heal");
    publish(&healed_client, &plane, &event).await;
    assert!(
        acked_within(&plane, &event.id, WIRE_BOUND).await,
        "a healed plane acknowledges"
    );
    let location = an_application_445();
    let commit = a_commit_445();
    for classed in [&location, &commit] {
        publish(&healed_client, &plane, classed).await;
        assert!(stored_within(&plane, &classed.id, WIRE_BOUND).await);
    }

    let subscription = SubscriptionId::new("healed");
    healed_client
        .subscribe_with_id(subscription.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    let page = page_within(&mut notifications, WIRE_BOUND, &subscription, &ledger).await;
    let seeded_tag = ledger
        .tag_of(&seeded.id)
        .expect("the ledger names what it delivered");
    assert!(
        page.iter().filter(|tag| **tag == seeded_tag).count() == 1,
        "a healed plane delivers each stored event once"
    );
    for classed in [&location, &commit] {
        let tag = ledger
            .tag_of(&classed.id)
            .expect("the ledger names what it delivered");
        assert!(
            page.iter().filter(|held| **held == tag).count() == 1,
            "a healed plane carries every class it was dropping, once"
        );
    }
    assert!(
        ledger.closed_messages().is_empty(),
        "a healed plane closes nothing"
    );
    assert!(
        ledger.eose() == 1,
        "a healed plane sends one EOSE for one subscription"
    );
}

// ---------------------------------------------------------------------------
// Rule 15
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_planes_rendering_names_its_handle_and_nothing_it_carries() {
    let plane = plane().await;
    let client = connected_client(&plane).await;
    let event = an_event("a needle");
    publish(&client, &plane, &event).await;
    assert!(acked_within(&plane, &event.id, WIRE_BOUND).await);

    let rendered = format!("{plane:?}");
    assert!(
        rendered.contains("SimRelay"),
        "the rendering must say what it is, or an empty string would pass this"
    );
    assert!(rendered.contains("simrelay#0"), "it must name its handle");
    let socket = socket_of(&plane);
    let port = socket.rsplit(':').next().unwrap_or_default().to_string();
    for needle in ["ws://", "127.0.0.1", socket.as_str(), port.as_str()] {
        assert!(
            !rendered.contains(needle),
            "a plane's rendering must carry no address: a loopback URL is still a URL"
        );
    }
    assert!(
        !rendered.contains(&event.id.to_hex()),
        "a plane's rendering must carry no event id"
    );
}

// ---------------------------------------------------------------------------
// FutureInnerHeader: a co-member's seal a relay plane cannot mint, and the one
// wire shape that grows the receiving engine's convergence buffer (mdk#757).
// ---------------------------------------------------------------------------

/// A fresh two-member circle on its own plane, for the future-header case. The
/// build boilerplate lives here so the case itself stays a sequence of proofs.
async fn future_header_world() -> ([SimDevice; 2], haven_soak::rig::SimCircle, SimRelay) {
    install_process_globals().expect("the ws:// loopback opt-in");
    let plane = plane().await;
    let urls = vec![plane.url().to_string()];
    let devices = [
        SimDevice::open(DeviceTag::new(0), &urls).expect("open alice"),
        SimDevice::open(DeviceTag::new(1), &urls).expect("open bob"),
    ];
    let outstanding = Arc::new(AtomicUsize::new(0));
    let circle = build_circle(
        CircleTag::new(0),
        &devices,
        std::slice::from_ref(&plane),
        &urls,
        &outstanding,
    )
    .await
    .expect("build a two-member circle");
    (devices, circle, plane)
}

/// A co-member seals a future-header 445 (a relay plane holds no group key, so it
/// cannot); an outsider replays it live through `Fault::Inject`; a real client
/// receives that replay; and the receiving ENGINE buffers it into convergence,
/// proven by the count seam growing and the stored row's state, not inferred.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_co_member_future_header_is_replayed_live_and_the_engine_buffers_it_into_convergence() {
    use haven_core::nostr::mls::types::{
        IngestOutcome, MessageState, OpenMlsContentKind, ScreenedIngest,
    };
    let (devices, circle, mut plane) = future_header_world().await;
    let group = circle.mls_group_id();
    let (alice, bob) = (&devices[0], &devices[1]);
    let bob_session = bob.session().expect("session");
    let tip = alice
        .manager()
        .expect("manager")
        .group_epoch(group)
        .await
        .expect("epoch");
    let forged = alice
        .session()
        .expect("session")
        .forge_future_header_445_for_test(group, tip + 4)
        .await
        .expect("alice seals a future-header 445");
    assert!(
        publish_witnessed(
            alice,
            std::slice::from_ref(&plane),
            std::slice::from_ref(&forged)
        )
        .await
        .expect("publish the seal")
        .is_some(),
        "the seal must be acked so the plane can serve it to the injection"
    );
    let client = connected_client(&plane).await;
    let subscription = subscribed_to_everything(&client, &plane, "watching").await;
    let mut notifications = client.notifications();
    let before = bob_session
        .convergence_buffer_len_for_test(group)
        .await
        .expect("count");
    assert_eq!(before, 0, "nothing is buffered before the injection");
    plane
        .apply(Fault::Inject(Forgery::FutureInnerHeader {
            source: forged.id,
            inner_epoch: tip + 4,
        }))
        .await
        .expect("the injection applies");
    // The stored original (served on subscribe) shares the content but keeps its
    // id; the injected replay is re-signed, so `id != forged.id` selects it.
    let replayed = message_within(&mut notifications, WIRE_BOUND, |message| {
        matches!(message, RelayMessage::Event { subscription_id, event }
            if subscription_id.as_ref() == &subscription
                && event.content == forged.content
                && event.id != forged.id)
    })
    .await
    .expect("a real client receives the injected replay live");
    let RelayMessage::Event {
        event: replayed, ..
    } = replayed
    else {
        unreachable!("the predicate above accepted only an EVENT")
    };
    assert!(
        replayed.id != forged.id,
        "the replay is re-signed by an outsider, so it is a distinct event on the wire"
    );
    let Ok(ScreenedIngest::Ingested(effects)) =
        bob_session.process_event_typed_for_test(&replayed).await
    else {
        panic!("a co-member-peelable replay passes pre-authentication and reaches the engine");
    };
    assert!(
        matches!(effects.outcome, IngestOutcome::Buffered { .. }),
        "a future-epoch application message is buffered, not delivered or dropped"
    );
    let after = bob_session
        .convergence_buffer_len_for_test(group)
        .await
        .expect("count");
    assert_eq!(
        after, 1,
        "the injected replay grew the receiving engine's convergence buffer — proven, not inferred"
    );
    let record = bob_session
        .stored_convergence_input_for_test(group, OpenMlsContentKind::Application, tip + 1)
        .await
        .expect("the buffered future-epoch row is present");
    let probe = bob_session
        .stored_message_record_for_test(&record.id)
        .await
        .expect("read the row")
        .expect("the row the locator just returned exists");
    assert!(
        probe.state != MessageState::PeelDeferred,
        "the row is in the convergence buffer, not the capped PeelDeferred store: a \
         PeelDeferred row is raw transport and would not have projected into the count above"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injected_outsider_seal_reaches_the_client_and_no_store_holds_it() {
    let mut plane = plane().await;
    let client = connected_client(&plane).await;
    let subscription = subscribed_to_everything(&client, &plane, "watching").await;
    let mut notifications = client.notifications();

    plane
        .apply(Fault::Inject(Forgery::OutsiderSeal {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await
        .expect("the injection applies");

    let message = message_within(&mut notifications, WIRE_BOUND, |message| {
        matches!(message, RelayMessage::Event { subscription_id, .. }
            if subscription_id.as_ref() == &subscription)
    })
    .await
    .expect("the forged event reaches a subscribed client");
    let RelayMessage::Event { event, .. } = message else {
        unreachable!("the predicate above accepted only an EVENT")
    };

    assert!(
        event
            .tags
            .iter()
            .filter(|tag| tag.kind().as_str() == "h")
            .count()
            == 1,
        "one routing tag: this one parses AND decodes, so the PEEL is what refuses it"
    );
    assert!(
        !plane.stored(&event.id).await.expect("the store reads"),
        "an injection is never retained"
    );
}

/// An injection is written on each connection only for the subscriptions THAT
/// connection opened. Two clients, one subscription each: the frame reaches
/// both, once each — never once per subscription on every socket, which would
/// hand each client a frame for a REQ it never opened and, on a pool that
/// notifies an event once per id, spend the one notification its own REQ was
/// owed. That is the difference between "the wire carried it" and "the engine
/// behind the socket ever saw it".
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_injection_reaches_each_connection_once_and_only_on_its_own_subscription() {
    let mut plane = plane().await;
    let first = connected_client(&plane).await;
    let first_sub = subscribed_to_everything(&first, &plane, "first").await;
    let second = connected_client(&plane).await;
    // Not `subscribed_to_everything`: that helper waits for the FIRST REQ to
    // cross, which the first client already satisfied. The second REQ must
    // have crossed too, or the injection is asked before this subscription is
    // open and its absence on the second socket would be correct.
    let second_sub = SubscriptionId::new("second");
    second
        .subscribe_with_id(second_sub.clone(), Filter::new(), None)
        .await
        .expect("the REQ goes out");
    let ledger = plane.ledger().clone();
    reaching(WIRE_BOUND, 2, move || ledger.reqs()).await;
    let mut first_notifications = first.notifications();
    let mut second_notifications = second.notifications();

    plane
        .apply(Fault::Inject(Forgery::OutsiderSeal {
            group_id: A_CIRCLES_ROUTING_ID,
        }))
        .await
        .expect("the injection applies");
    let forged = injected_within(&plane, WIRE_BOUND).await;

    for (notifications, own) in [
        (&mut first_notifications, &first_sub),
        (&mut second_notifications, &second_sub),
    ] {
        let message = message_within(
            notifications,
            WIRE_BOUND,
            |message| matches!(message, RelayMessage::Event { event, .. } if event.id == forged),
        )
        .await
        .expect("each client receives the injection");
        let RelayMessage::Event {
            subscription_id, ..
        } = message
        else {
            unreachable!("the predicate above accepted only an EVENT")
        };
        assert!(
            subscription_id.as_ref() == own,
            "the frame a client receives names the subscription IT opened"
        );
    }
    let ledger = plane.ledger().clone();
    assert!(
        reaching(WIRE_BOUND, 2, move || ledger.delivered(&forged)).await == 2,
        "one frame per connection: a second frame on either socket would name a \
         subscription that socket never opened"
    );
}
