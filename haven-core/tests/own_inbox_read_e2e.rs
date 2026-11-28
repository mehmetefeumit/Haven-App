//! The user's own inbox reads (`RelayManager::read_own_inbox_per_relay`, and
//! the relay-list pass's inbox probe the relay settings board shows,
//! `OwnRelayBoard::ask_inbox_reads`), against relays that serve gift wraps
//! only to their authenticated recipient.
//!
//! What is promised (owner-directed 2026-11-16, White Noise parity): an own
//! inbox read answers the relay's NIP-42 challenge with the identity key and
//! is then served what it stores — whether the relay spells its refusal
//! `auth-required:` (the pool resends the REQ) or `ERROR: auth-required:` as
//! strfry and damus do (Haven sends it again under a new id) — and a relay
//! that still refuses after the answer is `Refused`, never served or "not
//! finished". The anonymous publish client on the same relay never answers.
//! No challenge, relay address or key reaches a log.

mod helpers;

use std::sync::Arc;

use haven_core::relay::maintenance::OwnRelayBoard;
use haven_core::relay::nip42::Nip42Signer;
use haven_core::relay::recording_front::RecordingFront;
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};
use haven_core::relay::{InboxRead, RelayManager};
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines};
use nostr::{Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, RelayUrl, Tag};
use nostr_relay_builder::builder::RelayBuilder;
use nostr_relay_builder::{LocalRelay, MockRelay};
use nostr_sdk::Client;
use tempfile::TempDir;

/// The identity, and the signer its circle manager hands out.
struct Identity {
    keys: Keys,
    signer: Arc<Nip42Signer>,
    _store: TempDir,
}

fn identity() -> Identity {
    let keys = Keys::generate();
    let (signer, store) = helpers::nip42_signer_of(&keys);
    Identity {
        keys,
        signer,
        _store: store,
    }
}

/// A gift wrap addressed to `to`, as an inviter's is: signed by a one-time key.
fn wrap_for(to: &Keys) -> Event {
    EventBuilder::new(Kind::GiftWrap, "sealed")
        .tag(Tag::public_key(to.public_key()))
        .sign_with_keys(&Keys::generate())
        .expect("a wrap signs")
}

/// Stores `event` on the relay at `url` from a plain client.
async fn store(url: &str, event: &Event) {
    let sender = Client::builder().build();
    sender.add_relay(url).await.expect("add the relay");
    sender.connect().await;
    sender
        .send_event_to([url], event)
        .await
        .expect("the relay takes the event");
    sender.shutdown().await;
}

/// Each recorded text frame on `conn`, parsed.
fn frames_on(front: &RecordingFront, conn: usize) -> Vec<serde_json::Value> {
    front
        .frames()
        .into_iter()
        .filter(|frame| frame.conn == conn && !frame.binary)
        .map(|frame| serde_json::from_str(&frame.text).expect("a client frame is JSON"))
        .collect()
}

/// The verbs of the frames on `conn`, in order, with each REQ's id.
fn verbs_on(front: &RecordingFront, conn: usize) -> Vec<(String, Option<String>)> {
    frames_on(front, conn)
        .iter()
        .map(|frame| {
            let verb = frame[0].as_str().expect("a verb").to_owned();
            let id = (verb == "REQ").then(|| frame[1].as_str().expect("an id").to_owned());
            (verb, id)
        })
        .collect()
}

/// The one `AUTH` answer on `conn`: kind 22242 under `identity`, valid, its
/// `relay` tag the address dialled. Returns the challenge it answered.
fn the_one_answer(front: &RecordingFront, conn: usize, identity: &Keys) -> String {
    let answers: Vec<Event> = frames_on(front, conn)
        .into_iter()
        .filter(|frame| frame[0] == "AUTH")
        .map(|frame| Event::from_json(frame[1].to_string()).expect("an AUTH event"))
        .collect();
    assert_eq!(answers.len(), 1, "one challenge, one answer");
    let answer = &answers[0];
    assert!(answer.verify().is_ok(), "the answer does not verify");
    assert_eq!(answer.kind, Kind::Authentication);
    assert_eq!(answer.pubkey, identity.public_key());
    let tags: Vec<Vec<String>> = answer.tags.iter().map(|t| t.as_slice().to_vec()).collect();
    assert_eq!(tags.len(), 2);
    assert_eq!(tags[0][0], "challenge");
    assert_eq!(
        tags[1],
        [
            "relay".to_owned(),
            RelayUrl::parse(front.url()).expect("url").to_string()
        ]
    );
    tags[0][1].clone()
}

/// No `AUTH` on `conn`.
fn no_answer_on(front: &RecordingFront, conn: usize) -> bool {
    frames_on(front, conn)
        .iter()
        .all(|frame| frame[0] != "AUTH")
}

/// A relay that refuses an inbox read with `auth-required:` exactly
/// (`nostr-relay-builder`'s `auth_dm`, which also serves an inbox only to the
/// key that authenticated): the own read answers, the pool resends the REQ
/// under the same id, and the stored Welcome is served. The settings probe
/// reads it `Served` too, on a connection of its own; the anonymous client is
/// refused and answers nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_serving_an_inbox_only_to_its_owner_serves_the_own_read() {
    let me = identity();
    let relay = LocalRelay::new(RelayBuilder::default().auth_dm(true));
    relay.run().await.expect("the relay runs");
    let relay_url = relay.url().await.to_string();
    let wrap = wrap_for(&me.keys);
    store(&relay_url, &wrap).await;
    let front = RecordingFront::start(&relay_url);
    let inbox = vec![front.url().to_owned()];

    let read = RelayManager::read_own_inbox_per_relay(&me.signer, None, 10, &inbox).await;
    assert_eq!(read.len(), 1);
    assert_eq!(read[0].inbox_read(), InboxRead::Served);
    assert!(
        read[0].events == [wrap],
        "the stored Welcome was not served"
    );
    the_one_answer(&front, 0, &me.keys);
    let reqs: Vec<Option<String>> = verbs_on(&front, 0)
        .into_iter()
        .filter(|(verb, _)| verb == "REQ")
        .map(|(_, id)| id)
        .collect();
    assert!(
        reqs.len() == 2 && reqs[0] == reqs[1],
        "the pool's resend under the same id is not what was read: {reqs:?}"
    );
    tokio::time::timeout(helpers_budget(), front.wait_closed(1))
        .await
        .expect("the identity connection is closed when its read returns");

    let manager = RelayManager::new();
    let board = OwnRelayBoard::default();
    board
        .ask_inbox_reads(&me.signer, board.inbox_reads_generation(), &inbox)
        .await;
    let reads = board.snapshot().inbox_reads;
    assert_eq!(reads.len(), 1);
    assert_eq!(reads[0].read, InboxRead::Served);
    let anonymous = manager
        .fetch_events_per_relay(
            Filter::new()
                .kind(Kind::GiftWrap)
                .pubkey(me.keys.public_key()),
            &inbox,
        )
        .await
        .expect("the per-relay fetch never fails as a whole");
    manager.shutdown().await;
    assert_eq!(anonymous[0].inbox_read(), InboxRead::Refused);

    let answered: Vec<usize> = (0..front.connections())
        .filter(|&conn| !no_answer_on(&front, conn))
        .collect();
    let anonymous_conn = front
        .frames()
        .iter()
        .rfind(|frame| frame.text.starts_with(r#"["REQ""#))
        .expect("the anonymous read reached the front")
        .conn;
    assert!(
        answered.len() == 2 && answered[0] == 0 && !answered.contains(&anonymous_conn),
        "the read and the probe each answered on a connection of its own, and \
         the anonymous client never did: {answered:?}"
    );
}

/// strfry's refusal (`ERROR: auth-required:`, which the pool drops): the own
/// read answers the challenge, sends its REQ once more under a new id, and
/// is served. The front checks the answer itself. The anonymous publish
/// client, refused on the same front, never answers. Nothing identifying is
/// logged.
#[tokio::test(flavor = "current_thread")]
async fn a_strfry_gated_inbox_is_read_after_its_wrapped_refusal() {
    let me = identity();
    let relay = MockRelay::run().await.expect("an in-process relay");
    let relay_url = relay.url().await.to_string();
    let wrap = wrap_for(&me.keys);
    store(&relay_url, &wrap).await;
    let front = RecordingFront::start_gating(&relay_url);
    let inbox = vec![front.url().to_owned()];

    let mut read = Vec::new();
    let mut anonymous = Vec::new();
    let lines = capture_haven_log_here(async {
        read = RelayManager::read_own_inbox_per_relay(&me.signer, None, 10, &inbox).await;
        let manager = RelayManager::new();
        anonymous = manager
            .fetch_events_per_relay(
                Filter::new()
                    .kind(Kind::GiftWrap)
                    .pubkey(me.keys.public_key()),
                &inbox,
            )
            .await
            .expect("the per-relay fetch never fails as a whole");
        manager.shutdown().await;
    })
    .await;

    assert_eq!(read[0].inbox_read(), InboxRead::Served);
    assert!(
        read[0].events == [wrap],
        "the stored Welcome was not served"
    );
    // The `CLOSE` the pool sends at the `EOSE` races the connection's
    // shutdown; it is not what is promised.
    let verbs: Vec<_> = verbs_on(&front, 0)
        .into_iter()
        .filter(|(verb, _)| verb != "CLOSE")
        .collect();
    assert_eq!(
        verbs
            .iter()
            .map(|(verb, _)| verb.as_str())
            .collect::<Vec<_>>(),
        ["REQ", "AUTH", "REQ"],
        "{verbs:?}"
    );
    assert_ne!(
        verbs[0].1, verbs[2].1,
        "the REQ was not sent under a new id"
    );
    let challenge = the_one_answer(&front, 0, &me.keys);
    assert_eq!(anonymous[0].inbox_read(), InboxRead::Refused);
    assert!(
        no_answer_on(&front, 1),
        "the anonymous publish client answered the challenge"
    );

    let lines = haven_core_lines(&lines);
    assert_some_line_from(&lines, "haven_core");
    assert_no_needles(
        &lines,
        &[
            challenge.as_str(),
            front.url(),
            relay_url.as_str(),
            me.keys.public_key().to_hex().as_str(),
        ],
    );
}

/// A relay that refuses the read again after the answer to its challenge was
/// accepted: `Refused` — the refusal an invitation there is out of reach by,
/// not a read that did not finish — and the REQ is asked no third time. The
/// relay challenges at every REQ and accepts every answer, so it would be
/// asked again if the connection answered a second challenge (the pool
/// resends a refused REQ after every `Authenticated`); the frames are counted
/// once the socket is closed, so nothing the client sent is left uncounted.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_refuses_after_authentication_is_refused() {
    let me = identity();
    let relay = ScriptedRelay::start();
    relay.accept_auth();
    relay.answer(
        |_| true,
        vec![
            Frame::Text(serde_json::json!(["AUTH", "scripted-challenge-5e1d"]).to_string()),
            Frame::Closed("auth-required: still not yours".to_owned()),
        ],
    );
    let front = RecordingFront::start(relay.url());
    let inbox = vec![front.url().to_owned()];

    let read = RelayManager::read_own_inbox_per_relay(&me.signer, None, 10, &inbox).await;

    assert_eq!(read[0].inbox_read(), InboxRead::Refused);
    tokio::time::timeout(helpers_budget(), front.wait_closed(1))
        .await
        .expect("the identity connection is closed when its read returns");
    let reqs = verbs_on(&front, 0)
        .into_iter()
        .filter(|(verb, _)| verb == "REQ")
        .count();
    assert_eq!(reqs, 2, "one second chance, never a third REQ");
    assert!(
        !no_answer_on(&front, 0),
        "the read was refused without answering the challenge"
    );
    the_one_answer(&front, 0, &me.keys);
}

/// The scaled wait every bounded await here gets.
fn helpers_budget() -> std::time::Duration {
    std::time::Duration::from_secs(20)
        * std::env::var("HAVEN_TEST_WAIT_SCALE")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|s| *s >= 1)
            .unwrap_or(1)
}
