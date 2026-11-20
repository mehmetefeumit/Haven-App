//! The identity's NIP-42 connections (`relay::identity`), against real and
//! scripted relays behind a frame recorder.
//!
//! What is promised: an identity connection answers a relay's challenge with
//! exactly the answer NIP-42 asks for, under the identity key and nothing
//! else, and is then served what the relay gates — while the anonymous client
//! on the same relay is not; it sends a signed event at most once after it
//! authenticated, reads the outcome off the relay's own `OK` frames, carries
//! no REQ when it is registered to write, and closes its socket whether its
//! call finishes or is dropped mid-wait.

mod helpers;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::identity::{
    send_signed_once_authenticated, with_identity_relay, AuthSendOutcome, IdentityUse, NotDialled,
    AUTH_WAIT,
};
use haven_core::relay::nip42::Nip42Signer;
use haven_core::relay::recording_front::RecordingFront;
use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};
use haven_core::relay::RelayManager;
use helpers::{assert_no_needles, assert_some_line_from, capture_haven_log_here, haven_core_lines};
use nostr::{
    Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, PublicKey, RelayUrl, Tag, Timestamp,
};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::LocalRelay;
use nostr_sdk::pool::relay::ReqExitPolicy;
use nostr_sdk::Client;
use tempfile::TempDir;

/// The `OK` window every send here is given.
const ACK: Duration = Duration::from_secs(5);

/// The longest anything here may take to reach the recorder, unscaled.
const WAIT: Duration = Duration::from_secs(20);

fn budget() -> Duration {
    WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

/// The identity, and the signer the circle manager built from it.
struct Identity {
    keys: Keys,
    signer: Arc<Nip42Signer>,
    _dir: TempDir,
}

fn identity() -> Identity {
    let keys = Keys::generate();
    let dir = TempDir::new().expect("temp dir");
    let circle = CircleManager::new_unencrypted(dir.path(), &keys).expect("a circle manager");
    let signer = circle.nip42_signer();
    Identity {
        keys,
        signer,
        _dir: dir,
    }
}

fn url(raw: &str) -> RelayUrl {
    RelayUrl::parse(raw).expect("a relay url")
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

/// The verbs of the frames on `conn`, in order.
fn verbs_on(front: &RecordingFront, conn: usize) -> Vec<String> {
    frames_on(front, conn)
        .iter()
        .map(|frame| frame[0].as_str().expect("a verb").to_owned())
        .collect()
}

/// The events of the `EVENT` frames on `conn`.
fn events_on(front: &RecordingFront, conn: usize) -> Vec<Event> {
    frames_on(front, conn)
        .into_iter()
        .filter(|frame| frame[0] == "EVENT")
        .map(|frame| Event::from_json(frame[1].to_string()).expect("an event"))
        .collect()
}

fn auth_frames(front: &RecordingFront) -> usize {
    front
        .frames()
        .iter()
        .filter(|frame| frame.text.starts_with(r#"["AUTH""#))
        .count()
}

/// The one `AUTH` on `conn`, checked against NIP-42: kind 22242, no content,
/// the `challenge` tag then the `relay` tag naming the address dialled, signed
/// by `identity` just now. Returns the challenge it answered.
fn the_one_answer(front: &RecordingFront, conn: usize, identity: PublicKey) -> String {
    let answers: Vec<Event> = frames_on(front, conn)
        .into_iter()
        .filter(|frame| frame[0] == "AUTH")
        .map(|frame| Event::from_json(frame[1].to_string()).expect("an AUTH event"))
        .collect();
    assert_eq!(answers.len(), 1, "one challenge, one answer");
    let answer = &answers[0];
    assert!(
        answer.verify().is_ok(),
        "the answer's id or signature is wrong"
    );
    assert_eq!(answer.kind, Kind::Authentication);
    assert_eq!(answer.content, "");
    assert_eq!(answer.pubkey, identity, "the answer is not the identity's");
    let tags: Vec<Vec<String>> = answer
        .tags
        .iter()
        .map(|tag| tag.as_slice().to_vec())
        .collect();
    assert_eq!(
        tags.len(),
        2,
        "the answer carries a tag besides challenge and relay"
    );
    assert_eq!(tags[0][0], "challenge");
    assert_eq!(
        tags[1],
        ["relay".to_owned(), url(front.url()).to_string()],
        "the relay tag is not the address dialled"
    );
    let skew = answer
        .created_at
        .as_secs()
        .abs_diff(Timestamp::now().as_secs());
    assert!(skew <= 60, "the answer is dated {skew}s away from now");
    tags[0][1].clone()
}

/// A fresh event, signed by a key of its own as a kind 445 is.
fn one_time_event() -> Event {
    EventBuilder::text_note("signed once, sent as it is")
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs")
}

/// A relay that holds a kind 1059 for `identity` and serves it only to that
/// identity, once it has authenticated (`nostr-relay-builder`'s `auth_dm`,
/// damus's inbox rule): Haven's own inbox reads, which the anonymous client
/// cannot make.
#[tokio::test(flavor = "current_thread")]
async fn an_identity_read_is_served_the_gift_wrap_an_anonymous_read_is_refused() {
    let me = identity();
    let relay = LocalRelay::new(RelayBuilder::default().auth_dm(true));
    relay.run().await.expect("the relay runs");
    let relay_url = relay.url().await.to_string();
    let wrap = EventBuilder::new(Kind::GiftWrap, "sealed")
        .tag(Tag::public_key(me.keys.public_key()))
        .sign_with_keys(&Keys::generate())
        .expect("a wrap signs");
    let sender = Client::builder().build();
    sender.add_relay(&relay_url).await.expect("add the relay");
    sender.connect().await;
    sender
        .send_event_to([relay_url.as_str()], &wrap)
        .await
        .expect("the relay takes the wrap");
    sender.shutdown().await;

    let front = RecordingFront::start(&relay_url);
    let filter = Filter::new()
        .kind(Kind::GiftWrap)
        .pubkey(me.keys.public_key());
    let front_url = url(front.url());
    let mut served = Vec::new();
    let mut anonymous = Vec::new();
    let lines = capture_haven_log_here(async {
        served = with_identity_relay(
            Arc::clone(&me.signer),
            &front_url,
            IdentityUse::Read,
            |read| {
                let filter = filter.clone();
                async move {
                    read.relay
                        .fetch_events(filter, budget(), ReqExitPolicy::ExitOnEOSE)
                        .await
                        .expect("the read completes once authenticated")
                        .into_iter()
                        .collect::<Vec<_>>()
                }
            },
        )
        .await
        .expect("the relay is dialled");
        tokio::time::timeout(budget(), front.wait_closed(1))
            .await
            .expect("the identity connection is closed when its call returns");

        let manager = RelayManager::new();
        anonymous = manager
            .fetch_events_per_relay(filter.clone(), &[front.url().to_owned()])
            .await
            .expect("the per-relay fetch never fails as a whole");
        manager.shutdown().await;
    })
    .await;

    assert!(
        served == [wrap],
        "the identity read was not served the wrap"
    );
    assert!(
        anonymous.len() == 1 && anonymous[0].events.is_empty() && !anonymous[0].drained,
        "the anonymous client was served, or took the refusal for a whole answer"
    );
    let challenge = the_one_answer(&front, 0, me.keys.public_key());
    assert!(
        !verbs_on(&front, 0).contains(&"EVENT".to_owned()),
        "a read-only identity connection sent an event"
    );
    assert!(
        !verbs_on(&front, 1).contains(&"AUTH".to_owned()),
        "the anonymous client answered the challenge"
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

/// A relay that takes an event only from an authenticated connection
/// (`nostr-relay-builder`'s write mode, as damus gates an inbox write): the
/// identity connection sends the byte-identical event, answers the challenge
/// the first send drew, sends it once more and is told `OK true` — and the
/// relay then holds it. No REQ rides the write-only connection.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_gated_relay_takes_the_event_once_the_identity_has_answered() {
    let me = identity();
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Write,
    }));
    relay.run().await.expect("the relay runs");
    let relay_url = relay.url().await.to_string();
    let front = RecordingFront::start(&relay_url);
    let event = one_time_event();

    let outcome =
        send_signed_once_authenticated(Arc::clone(&me.signer), &url(front.url()), &event, ACK)
            .await;

    assert_eq!(outcome, AuthSendOutcome::Accepted);
    assert_eq!(verbs_on(&front, 0), ["EVENT", "AUTH", "EVENT"]);
    assert!(
        events_on(&front, 0)
            .iter()
            .all(|sent| sent.as_json() == event.as_json()),
        "an event other than the signed one was sent"
    );
    the_one_answer(&front, 0, me.keys.public_key());
    tokio::time::timeout(budget(), front.wait_closed(1))
        .await
        .expect("the identity connection is closed when its call returns");

    let manager = RelayManager::new();
    let held = manager
        .fetch_events(Filter::new().id(event.id), &[relay_url], None)
        .await
        .expect("the relay serves reads to anyone");
    manager.shutdown().await;
    assert!(held == [event], "the relay does not hold the event");
}

/// Authenticated and still refused (a NIP-70 protected event whose author is
/// not the identity): every frame was answered `OK false`, one after the
/// connection authenticated — a refusal, never "unanswered".
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_refuses_after_authentication_is_a_refusal() {
    let me = identity();
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Write,
    }));
    relay.run().await.expect("the relay runs");
    let front = RecordingFront::start(&relay.url().await.to_string());
    let protected = EventBuilder::text_note("only its author may publish it")
        .tag(Tag::protected())
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs");

    let outcome =
        send_signed_once_authenticated(Arc::clone(&me.signer), &url(front.url()), &protected, ACK)
            .await;

    assert_eq!(outcome, AuthSendOutcome::Refused);
    assert_eq!(verbs_on(&front, 0), ["EVENT", "AUTH", "EVENT"]);
}

/// A refusal that authentication would not change (`blocked:`) ends the call:
/// no challenge is answered and the event is sent once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refusal_authentication_would_not_change_draws_no_answer() {
    let me = identity();
    let relay = ScriptedRelay::start();
    relay.refuse(|_| true);
    let front = RecordingFront::start(relay.url());

    let outcome = send_signed_once_authenticated(
        Arc::clone(&me.signer),
        &url(front.url()),
        &one_time_event(),
        ACK,
    )
    .await;

    assert_eq!(outcome, AuthSendOutcome::NotAuthenticated);
    assert_eq!(verbs_on(&front, 0), ["EVENT"]);
}

/// `auth-required:` and a challenge, and an answer the relay never accepts:
/// the event is never sent a second time, and nothing was exposed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_answer_the_relay_never_accepts_sends_the_event_no_second_time() {
    let me = identity();
    let relay = ScriptedRelay::start();
    relay.on_publish(gate);
    let front = RecordingFront::start(relay.url());

    let started = tokio::time::Instant::now();
    let outcome = send_signed_once_authenticated(
        Arc::clone(&me.signer),
        &url(front.url()),
        &one_time_event(),
        ACK,
    )
    .await;

    assert_eq!(outcome, AuthSendOutcome::NotAuthenticated);
    assert_eq!(verbs_on(&front, 0), ["EVENT", "AUTH"]);
    assert!(
        started.elapsed() >= AUTH_WAIT,
        "the call gave up before the authentication wait ran out"
    );
}

/// The challenge and `auth-required:` a gated relay answers an anonymous
/// write with.
fn gate(event: &Event) -> Verdict {
    Verdict::Frames(vec![
        serde_json::json!(["AUTH", "scripted-challenge-91c2"]).to_string(),
        serde_json::json!(["OK", event.id, false, "auth-required: sign in"]).to_string(),
    ])
}

/// Authenticated, sent again, and never answered: the relay may hold the
/// event, so the outcome says so.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_sent_after_authentication_and_never_answered_is_unanswered() {
    let me = identity();
    let relay = ScriptedRelay::start();
    relay.accept_auth();
    let offers = AtomicUsize::new(0);
    relay.on_publish(move |event| {
        if offers.fetch_add(1, Ordering::SeqCst) == 0 {
            gate(event)
        } else {
            Verdict::KeepSilently
        }
    });
    let front = RecordingFront::start(relay.url());
    let event = one_time_event();

    let outcome = send_signed_once_authenticated(
        Arc::clone(&me.signer),
        &url(front.url()),
        &event,
        Duration::from_secs(2),
    )
    .await;

    assert_eq!(outcome, AuthSendOutcome::Unanswered);
    assert_eq!(verbs_on(&front, 0), ["EVENT", "AUTH", "EVENT"]);
    assert!(
        relay.published() == [event],
        "the relay kept the second send"
    );
}

/// `duplicate:` is a relay that already holds the event, even under `false`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_duplicate_is_accepted() {
    let me = identity();
    let relay = ScriptedRelay::start();
    relay.on_publish(|event| {
        Verdict::Frames(vec![serde_json::json!([
            "OK",
            event.id,
            false,
            "duplicate: already have it"
        ])
        .to_string()])
    });

    let outcome = send_signed_once_authenticated(
        Arc::clone(&me.signer),
        &url(relay.url()),
        &one_time_event(),
        ACK,
    )
    .await;

    assert_eq!(outcome, AuthSendOutcome::Accepted);
}

/// The call dropped while it waits on the relay's verdict on its answer — a
/// wake's budget ending mid-retry — still closes the authenticated socket,
/// and nothing dials or answers again. Haven adds nothing for this: the pool's
/// last handle shuts it down when dropped (`atomic_destructor`), and this is
/// what goes red the day an SDK bump stops doing so.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_dropped_mid_wait_still_closes_its_identity_socket() {
    let me = identity();
    let relay = ScriptedRelay::start();
    relay.on_publish(gate);
    let front = RecordingFront::start(relay.url());
    let target = url(front.url());
    let event = one_time_event();

    let answered = front.wait_for(|frames| frames.iter().any(|f| f.text.starts_with(r#"["AUTH""#)));
    tokio::select! {
        outcome = send_signed_once_authenticated(Arc::clone(&me.signer), &target, &event, ACK) => {
            panic!("the send finished before its answer was refused: {outcome:?}")
        }
        () = answered => {}
    }

    tokio::time::timeout(budget(), front.wait_closed(1))
        .await
        .expect("the dropped call's identity connection was left open");
    assert_eq!(front.connections(), 1, "the identity client dialled again");
    assert_eq!(auth_frames(&front), 1, "the identity client answered again");
}

/// A write-only connection holds no READ flag, so it can carry no REQ; a
/// read-only one holds no WRITE flag.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn each_direction_is_registered_alone() {
    let me = identity();
    let relay = ScriptedRelay::start();
    let target = url(relay.url());

    let (read, write, fetched) = with_identity_relay(
        Arc::clone(&me.signer),
        &target,
        IdentityUse::Write,
        |conn| async move {
            let fetched = conn
                .relay
                .fetch_events(Filter::new(), ACK, ReqExitPolicy::ExitOnEOSE)
                .await;
            (
                conn.relay.flags().has_read(),
                conn.relay.flags().has_write(),
                fetched.is_ok(),
            )
        },
    )
    .await
    .expect("the relay is dialled");
    assert!(
        !read && write && !fetched,
        "a write-only connection can read"
    );

    let (read, write) = with_identity_relay(
        Arc::clone(&me.signer),
        &target,
        IdentityUse::Read,
        |conn| async move {
            (
                conn.relay.flags().has_read(),
                conn.relay.flags().has_write(),
            )
        },
    )
    .await
    .expect("the relay is dialled");
    assert!(read && !write, "a read-only connection can write");
}

/// A relay Haven does not dial is not dialled: nothing is sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_haven_does_not_dial_is_sent_nothing() {
    let me = identity();
    let plaintext = url("ws://relay.example.com");
    assert_eq!(
        with_identity_relay(
            Arc::clone(&me.signer),
            &plaintext,
            IdentityUse::Read,
            |_| async {}
        )
        .await,
        Err(NotDialled)
    );
    assert_eq!(
        send_signed_once_authenticated(me.signer, &plaintext, &one_time_event(), ACK).await,
        AuthSendOutcome::NotSent
    );
}

#[tokio::test]
async fn the_signer_refuses_a_profile_event() {
    use nostr::signer::NostrSigner as _;

    let me = identity();
    let mut unsigned =
        EventBuilder::auth("challenge", url("wss://relay.example.com")).build(me.keys.public_key());
    unsigned.kind = Kind::Metadata;
    unsigned.id = None;
    assert!(
        me.signer.sign_event(unsigned).await.is_err(),
        "a kind-0 event was signed under the identity key"
    );
}
