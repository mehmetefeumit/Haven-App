//! The authenticated resend a relay that answers `auth-required:` is given
//! (owner decisions D1b and D1c), against real and scripted relays behind a
//! frame recorder.
//!
//! What is promised:
//!
//! * a recorded kind-445 event a relay wants authentication for is sent once
//!   more, byte for byte, as the identity on a write-only connection of its
//!   own, inside the same fanout call; it is accepted only on that relay's
//!   own acknowledgement, refused only when both phases are proven, and an
//!   unanswered resend stays possibly exposed and is sent again unchanged
//!   (Security Rule 13);
//! * a Welcome is published anonymously, and only a relay that answers
//!   `auth-required:` is sent it once more as the inviter — never one that
//!   took it, and never after another relay took it in the same pass;
//! * a location gets one anonymous and at most one authenticated attempt,
//!   and none that could end past its expiration;
//! * the publish client never answers a challenge, every retry socket carries
//!   only `EVENT` and `AUTH`, and nothing logged names the relay, the
//!   challenge or the identity (Security Rule 15).
//!
//! No wait here is a sleep: each awaits a product outcome, bounded by a
//! budget scaled for instrumented runs.

mod helpers;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleConfig, MemberKeyPackage};
use haven_core::nostr::mls::types::TransportMessage;
use haven_core::nostr::mls::types::{
    TransportEndpointFailureKind, TransportEndpointRejectionCategory,
};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::{
    DriveMode, EvolutionStatus, FanoutSend, FanoutTargetOutcome, Publishing, UnrecordedAnswer,
    UnrecordedPublisher, WallClock,
};
use haven_core::relay::identity::AuthSendOutcome;
use haven_core::relay::nip42::Nip42Signer;
use haven_core::relay::recording_front::RecordingFront;
use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};
use haven_core::relay::{allow_ws_loopback_for_test, FanoutTransport, RelayError, RelayManager};
use helpers::{
    assert_no_needles, assert_some_line_from, capture_haven_log_here, create_key_package_event,
    haven_core_lines, CircleMember,
};
use nostr::{Event, EventBuilder, Filter, JsonUtil as _, Keys, Kind, PublicKey, Tag, Timestamp};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::{LocalRelay, MockRelay};

/// The longest a product outcome may take, unscaled.
const WAIT: Duration = Duration::from_mins(1);

fn budget() -> Duration {
    WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

async fn within<T>(what: &str, fut: impl Future<Output = T>) -> T {
    tokio::time::timeout(budget(), fut)
        .await
        .unwrap_or_else(|_| panic!("{what} did not finish within its budget"))
}

/// A relay that takes a write only from an authenticated connection, as
/// damus gates an inbox: `nostr-relay-builder`'s write mode.
async fn write_gated() -> (LocalRelay, String) {
    let _ = allow_ws_loopback_for_test();
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Write,
    }));
    relay.run().await.expect("the auth relay runs");
    let url = relay.url().await.to_string();
    (relay, url)
}

/// A signed kind-445 event in the engine's shape: an `h` tag, a one-time key.
fn group_event(tags: Vec<Tag>) -> Event {
    let mut builder = EventBuilder::new(Kind::Custom(445), "ciphertext")
        .tag(Tag::parse(["h", &"ab".repeat(32)]).expect("an h tag"));
    for tag in tags {
        builder = builder.tag(tag);
    }
    builder
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs")
}

fn as_message(event: &Event) -> TransportMessage {
    SessionManager::event_to_transport_message(event).expect("a kind-445 event converts")
}

/// A location event expiring `secs` from now.
fn location_expiring_in(secs: u64) -> Event {
    group_event(vec![Tag::expiration(Timestamp::from(
        Timestamp::now().as_secs() + secs,
    ))])
}

/// One fanout call to `target` through `transport`, as the driver makes it.
async fn call(
    transport: &FanoutTransport,
    target: &str,
    message: &TransportMessage,
) -> FanoutTargetOutcome {
    let taken = transport.take(target).await.expect("the relay is free");
    within("the fanout call", transport.publish(target, message, taken)).await
}

const fn classified(
    outcome: &FanoutTargetOutcome,
) -> Option<(
    TransportEndpointFailureKind,
    Option<TransportEndpointRejectionCategory>,
)> {
    match outcome {
        FanoutTargetOutcome::Accepted => None,
        FanoutTargetOutcome::Failed(failure) => {
            Some((failure.kind(), failure.rejection_category()))
        }
    }
}

/// The identity, its signer as the circle manager built it, and the manager.
fn identity() -> (CircleMember, Arc<Nip42Signer>) {
    let me = CircleMember::new();
    let signer = me.circle.nip42_signer();
    (me, signer)
}

/// Each recorded text frame, parsed, with its connection.
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

/// The verbs sent on `conn`, in order.
fn verbs_on(front: &RecordingFront, conn: usize) -> Vec<String> {
    frames(front)
        .into_iter()
        .filter(|(on, _)| *on == conn)
        .map(|(_, frame)| frame[0].as_str().expect("a verb").to_owned())
        .collect()
}

/// The connections whose frames include an `AUTH`.
fn authenticated_connections(front: &RecordingFront) -> Vec<usize> {
    let mut conns: Vec<usize> = frames(front)
        .into_iter()
        .filter(|(_, frame)| frame[0] == "AUTH")
        .map(|(conn, _)| conn)
        .collect();
    conns.dedup();
    conns
}

/// Every `EVENT` sent through `front`, on any connection.
fn events(front: &RecordingFront) -> Vec<Event> {
    frames(front)
        .into_iter()
        .filter(|(_, frame)| frame[0] == "EVENT")
        .map(|(_, frame)| Event::from_json(frame[1].to_string()).expect("an event"))
        .collect()
}

/// The one `AUTH` sent through `front`: signed by `identity` over the
/// challenge, naming the address dialled. Returns the challenge.
fn the_one_answer(front: &RecordingFront, identity: PublicKey) -> String {
    let answers: Vec<Event> = frames(front)
        .into_iter()
        .filter(|(_, frame)| frame[0] == "AUTH")
        .map(|(_, frame)| Event::from_json(frame[1].to_string()).expect("an AUTH event"))
        .collect();
    assert_eq!(answers.len(), 1, "one demand, one answer");
    let answer = &answers[0];
    assert!(answer.verify().is_ok(), "the answer does not verify");
    assert_eq!(answer.kind, Kind::Authentication);
    assert_eq!(answer.pubkey, identity, "the answer is not the identity's");
    let tags: Vec<Vec<String>> = answer.tags.iter().map(|t| t.as_slice().to_vec()).collect();
    assert_eq!(tags.len(), 2);
    assert_eq!(tags[0][0], "challenge");
    assert_eq!(tags[1][0], "relay");
    tags[0][1].clone()
}

/// The resend connection carries the event, the answer, the event: nothing
/// else, and every event on any connection is the one signed event.
fn assert_one_resend_of(front: &RecordingFront, event: &Event) {
    let resent = authenticated_connections(front);
    assert_eq!(
        resent.len(),
        1,
        "the relay was signed in to on other than one connection"
    );
    assert_eq!(
        verbs_on(front, resent[0]),
        ["EVENT", "AUTH", "EVENT"],
        "the resend connection carried something besides the event and the answer",
    );
    assert!(
        events(front).iter().all(|sent| sent.id == event.id
            && sent.sig == event.sig
            && sent.as_json() == event.as_json()),
        "an event other than the frozen one was sent",
    );
}

async fn held_by(relay_url: &str, event: &Event) -> bool {
    let manager = RelayManager::new();
    let held = manager
        .fetch_events(Filter::new().id(event.id), &[relay_url.to_owned()], None)
        .await
        .expect("the relay serves reads to anyone");
    manager.shutdown().await;
    held.iter().any(|kept| kept.id == event.id)
}

// ── D1c: recorded kind-445 events ───────────────────────────────────────────

/// The publish client never answers the challenge, so the anonymous call is
/// refused on every attempt; the authenticating transport then sends the
/// same bytes once more as the identity, the relay acknowledges them there,
/// and that acknowledgement — and nothing before it — is the call's.
#[tokio::test(flavor = "current_thread")]
async fn a_recorded_event_a_relay_wants_auth_for_is_accepted_on_the_authenticated_send() {
    let (me, signer) = identity();
    let (_relay, relay_url) = write_gated().await;
    let front = RecordingFront::start(&relay_url);
    let event = group_event(Vec::new());
    let message = as_message(&event);

    let mut outcome = None;
    let lines = capture_haven_log_here(async {
        let manager = RelayManager::new();
        let transport = manager.fanout_transport().authenticating(signer);
        outcome = Some(call(&transport, front.url(), &message).await);
        manager.shutdown().await;
    })
    .await;

    assert!(
        matches!(outcome, Some(FanoutTargetOutcome::Accepted)),
        "the authenticated acknowledgement was not the call's",
    );
    assert_one_resend_of(&front, &event);
    let challenge = the_one_answer(&front, me.keys.public_key());
    let anonymous = (0..front.connections())
        .filter(|conn| !authenticated_connections(&front).contains(conn))
        .flat_map(|conn| verbs_on(&front, conn))
        .collect::<Vec<_>>();
    assert!(
        anonymous == ["EVENT", "EVENT", "EVENT"],
        "the publish client's frames changed, or it answered the challenge",
    );
    assert!(
        held_by(&relay_url, &event).await,
        "the relay does not hold the event"
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
            event.id.to_hex().as_str(),
        ],
    );
}

/// What the relay answers each `EVENT` it is offered, by its place in line:
/// MDK's three anonymous attempts are told `auth-required:`, the resend's
/// first frame draws the challenge, and `after` decides the frames after.
fn auth_gate(after: impl Fn(usize, &Event) -> Verdict + Send + Sync + 'static) -> ScriptedRelay {
    let relay = ScriptedRelay::start();
    relay.accept_auth();
    let offers = AtomicUsize::new(0);
    relay.on_publish(move |event| match offers.fetch_add(1, Ordering::SeqCst) {
        0..=2 => Verdict::Refuse("auth-required: members only".to_owned()),
        3 => Verdict::Frames(vec![
            serde_json::json!(["AUTH", "scripted-challenge-5f0e"]).to_string(),
            serde_json::json!(["OK", event.id, false, "auth-required: sign in"]).to_string(),
        ]),
        n => after(n, event),
    });
    relay
}

/// Refused on every anonymous attempt, and refused again after the identity
/// signed in: both phases proven, so the call is a refusal a rollback may
/// act on — and nothing was kept.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_that_refuses_after_authentication_is_refused_only_with_both_phases_proven() {
    let (_me, signer) = identity();
    let relay = auth_gate(|_, _| Verdict::Refuse("blocked: not a member".to_owned()));
    let front = RecordingFront::start(relay.url());
    let event = group_event(Vec::new());

    let manager = RelayManager::new();
    let outcome = call(
        &manager.fanout_transport().authenticating(signer),
        front.url(),
        &as_message(&event),
    )
    .await;

    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::AuthRequired)
            )),
        "a refusal both phases proved was not returned as one",
    );
    assert_eq!(
        relay.offers(),
        5,
        "three anonymous attempts and the two-frame resend"
    );
    assert!(relay.published().is_empty());
    assert_one_resend_of(&front, &event);
}

/// The resend reaches the relay after the identity signed in, and its `OK` is
/// lost: the relay may hold the event, so the call is possibly exposed — never
/// a refusal — and the driver's next call sends the same bytes again, which
/// the relay that kept them acknowledges.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_resend_whose_ok_is_lost_stays_possibly_exposed_and_the_same_bytes_go_again() {
    let (_me, signer) = identity();
    let relay = auth_gate(|n, _| {
        if n == 4 {
            Verdict::KeepSilently
        } else {
            Verdict::Refuse("duplicate: already have it".to_owned())
        }
    });
    let front = RecordingFront::start(relay.url());
    let event = group_event(Vec::new());
    let message = as_message(&event);

    let manager = RelayManager::new();
    let transport = manager.fanout_transport().authenticating(signer);
    let first = call(&transport, front.url(), &message).await;
    assert!(
        classified(&first)
            == Some((
                TransportEndpointFailureKind::PossiblyExposed,
                Some(TransportEndpointRejectionCategory::AuthRequired)
            )),
        "an unanswered resend was classified as something a rollback could act on",
    );
    assert!(
        relay.published() == [event.clone()],
        "the relay kept the resend: that is the case"
    );

    let again = call(&transport, front.url(), &message).await;
    assert!(
        matches!(again, FanoutTargetOutcome::Accepted),
        "the relay that kept the event was not heard to hold it",
    );
    let sent = events(&front);
    assert!(sent.len() >= 6, "the event was not sent again");
    assert!(
        sent.iter().all(|e| e.as_json() == event.as_json()),
        "what was sent again is not the byte-identical event",
    );
}

/// A removal staged for a circle whose relay takes writes only from an
/// authenticated connection: through a transport that never authenticates,
/// every relay proved its refusal and the removal is undone; through the
/// product's authenticating transport, the relay's acknowledgement of the
/// resend confirms it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_removal_through_a_write_gated_relay_is_confirmed_only_by_the_authenticated_send() {
    for authenticates in [false, true] {
        let (_relay, relay_url) = write_gated().await;
        let inbox = MockRelay::run().await.expect("a relay");
        let inbox = vec![inbox.url().await.to_string()];
        let invitee = CircleMember::new();
        let package = MemberKeyPackage {
            key_package_event: create_key_package_event(invitee.session(), &invitee.keys, &inbox)
                .await,
            inbox_relays: inbox.clone(),
            nip65_relays: Vec::new(),
            nip65_write_relays: Vec::new(),
        };
        let founder = CircleMember::new();
        let pool = RelayManager::new();
        let transport = if authenticates {
            pool.fanout_transport()
                .authenticating(founder.circle.nip42_signer())
        } else {
            pool.fanout_transport()
        };
        let driver = Publishing {
            fanout: &transport,
            publisher: &pool,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let config = CircleConfig::new("Gated writes").with_relays(vec![relay_url.clone()]);
        let created = within(
            "the create",
            Box::pin(driver.create_circle(&founder.circle, &founder.keys, vec![package], &config)),
        )
        .await
        .expect("the circle is created");
        let gid = created.circle.mls_group_id;
        let epoch = founder.session().epoch(&gid).await.expect("an epoch");

        let removed = within(
            "the removal",
            Box::pin(driver.remove_members(&founder.circle, &gid, &[invitee.pubkey_hex()])),
        )
        .await
        .expect("the removal is made");

        let expected = if authenticates {
            EvolutionStatus::Confirmed
        } else {
            EvolutionStatus::RolledBack
        };
        assert_eq!(
            removed.status, expected,
            "authenticates={authenticates}: the removal was not resolved by what the relay \
             acknowledged",
        );
        assert_eq!(
            founder.session().epoch(&gid).await.expect("an epoch"),
            epoch + u64::from(authenticates),
            "authenticates={authenticates}: the epoch moved without an acknowledgement, or \
             stayed after one",
        );
        pool.shutdown().await;
    }
}

// ── D1b: Welcomes ──────────────────────────────────────────────────────────

/// An invite whose one inbox relay sits behind `front`, made through the
/// product's driver: what the create said of its Welcomes.
async fn invite_through(front: &RecordingFront) -> (CircleMember, usize) {
    let location = MockRelay::run().await.expect("a relay");
    let inbox = vec![front.url().to_owned()];
    let invitee = CircleMember::new();
    let package = MemberKeyPackage {
        key_package_event: create_key_package_event(invitee.session(), &invitee.keys, &inbox).await,
        inbox_relays: inbox,
        nip65_relays: Vec::new(),
        nip65_write_relays: Vec::new(),
    };
    let founder = CircleMember::new();
    let pool = RelayManager::new();
    let transport = pool
        .fanout_transport()
        .authenticating(founder.circle.nip42_signer());
    let driver = Publishing {
        fanout: &transport,
        publisher: &pool,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };
    let config = CircleConfig::new("Invite").with_relays(vec![location.url().await.to_string()]);
    let created = within(
        "the create",
        Box::pin(driver.create_circle(&founder.circle, &founder.keys, vec![package], &config)),
    )
    .await
    .expect("the circle is created");
    pool.shutdown().await;
    (founder, created.welcomes_sent)
}

/// An inbox relay that takes gift wraps only from an authenticated
/// connection: the anonymous publish ends at its first `auth-required:` —
/// a resend on the same socket is answered the same — and one authenticated
/// send as the inviter delivers the Welcome.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_an_inbox_relay_wants_auth_for_is_delivered_by_one_authenticated_send() {
    let (_relay, relay_url) = write_gated().await;
    let front = RecordingFront::start(&relay_url);

    let (founder, delivered) = invite_through(&front).await;

    assert_eq!(delivered, 1, "the Welcome was not delivered");
    let wraps = events(&front);
    let wrap = wraps.first().expect("the Welcome was sent").clone();
    assert_eq!(wrap.kind, Kind::GiftWrap);
    assert_one_resend_of(&front, &wrap);
    the_one_answer(&front, founder.keys.public_key());
    let anonymous: Vec<String> = (0..front.connections())
        .filter(|conn| !authenticated_connections(&front).contains(conn))
        .flat_map(|conn| verbs_on(&front, conn))
        .collect();
    assert!(
        anonymous == ["EVENT"],
        "the anonymous ladder went on after the relay asked for authentication, or \
         the publish client answered the challenge",
    );
    assert!(
        held_by(&relay_url, &wrap).await,
        "the relay does not hold the Welcome"
    );
}

/// An inbox relay that takes the Welcome anonymously is never signed in to.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_welcome_an_inbox_relay_takes_anonymously_draws_no_authentication() {
    let _ = allow_ws_loopback_for_test();
    let store = MockRelay::run().await.expect("a relay");
    let front = RecordingFront::start(store.url().await.as_str());

    let (_founder, delivered) = invite_through(&front).await;

    assert_eq!(delivered, 1);
    assert!(
        authenticated_connections(&front).is_empty(),
        "the inviter signed in to a relay that never asked",
    );
}

/// A publisher of what has no record whose first inbox relay answers at
/// once, and whose second answers `auth-required:` only after the first has.
struct Ordered {
    first: String,
    first_accepts: bool,
    first_answered: tokio::sync::Notify,
    authenticated: Mutex<Vec<String>>,
}

impl UnrecordedPublisher for Ordered {
    fn publish_unrecorded<'a>(
        &'a self,
        _event: &'a Event,
        relays: &'a [String],
    ) -> Pin<Box<dyn Future<Output = Vec<UnrecordedAnswer>> + Send + 'a>> {
        Box::pin(async move {
            if relays.first() == Some(&self.first) {
                self.first_answered.notify_one();
                return UnrecordedAnswer::all(relays, self.first_accepts);
            }
            self.first_answered.notified().await;
            vec![UnrecordedAnswer::AuthRequired; relays.len()]
        })
    }

    fn publish_authenticated<'a>(
        &'a self,
        _signer: Arc<Nip42Signer>,
        _event: &'a Event,
        relay: &'a str,
    ) -> Pin<Box<dyn Future<Output = AuthSendOutcome> + Send + 'a>> {
        self.authenticated
            .lock()
            .expect("lock")
            .push(relay.to_owned());
        Box::pin(async { AuthSendOutcome::Accepted })
    }
}

/// Once one relay has taken the Welcome, a relay that asks for
/// authentication is not signed in to: that send could only disclose who
/// sent it. When no relay took it, that relay gets its one authenticated
/// send, and its acknowledgement delivers the Welcome.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_authenticated_send_follows_another_relays_acceptance_of_the_welcome() {
    for first_accepts in [true, false] {
        let (first, gated) = (
            "wss://inbox-one.example.com".to_owned(),
            "wss://inbox-two.example.com".to_owned(),
        );
        let invitee = CircleMember::new();
        let inbox = vec![first.clone(), gated.clone()];
        let package = MemberKeyPackage {
            key_package_event: create_key_package_event(invitee.session(), &invitee.keys, &inbox)
                .await,
            inbox_relays: inbox,
            nip65_relays: Vec::new(),
            nip65_write_relays: Vec::new(),
        };
        let founder = CircleMember::new();
        let publisher = Ordered {
            first,
            first_accepts,
            first_answered: tokio::sync::Notify::new(),
            authenticated: Mutex::new(Vec::new()),
        };
        let transport = ScriptedFanout::default();
        let driver = Publishing {
            fanout: &transport as &dyn FanoutSend,
            publisher: &publisher,
            clock: &WallClock,
            deadline_ms: None,
            mode: &DriveMode::Full,
        };
        let config = CircleConfig::new("Two inboxes")
            .with_relays(vec!["wss://group.example.com".to_owned()]);
        let created = within(
            "the create",
            Box::pin(driver.create_circle(&founder.circle, &founder.keys, vec![package], &config)),
        )
        .await
        .expect("the circle is created");

        assert_eq!(
            created.welcomes_sent, 1,
            "first_accepts={first_accepts}: not delivered"
        );
        let authenticated = publisher.authenticated.lock().expect("lock").clone();
        if first_accepts {
            assert!(
                authenticated.is_empty(),
                "a relay was signed in to after another relay had taken the Welcome",
            );
        } else {
            assert!(
                authenticated == [gated],
                "the relay that asked was not given its one authenticated send",
            );
        }
    }
}

// ── D1c: locations ─────────────────────────────────────────────────────────

/// One anonymous attempt, refused for want of authentication, then one
/// authenticated attempt that the relay takes: the location is sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_a_relay_wants_auth_for_goes_once_anonymously_and_once_authenticated() {
    let (me, signer) = identity();
    let (_relay, relay_url) = write_gated().await;
    let front = RecordingFront::start(&relay_url);
    let event = location_expiring_in(228);

    let manager = RelayManager::new();
    let transport = manager.fanout_transport().authenticating(signer);
    let sent = within(
        "the location send",
        transport.publish_location(&event, &[front.url().to_owned()]),
    )
    .await
    .expect("the location reached a relay");

    assert!(
        matches!(sent.accepted_by.as_slice(), [by] if by == front.url()),
        "the relay that took the resend is not the one reported"
    );
    assert_one_resend_of(&front, &event);
    the_one_answer(&front, me.keys.public_key());
    let anonymous: Vec<String> = (0..front.connections())
        .filter(|conn| !authenticated_connections(&front).contains(conn))
        .flat_map(|conn| verbs_on(&front, conn))
        .collect();
    assert!(
        anonymous == ["EVENT"],
        "a location was sent anonymously more than once"
    );
}

/// A location whose expiration falls inside the resend's longest run gets no
/// authenticated attempt — and a transport that never authenticates makes
/// none: one anonymous attempt each, refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_location_is_never_resent_where_the_resend_could_end_past_its_expiration() {
    let (_me, signer) = identity();
    for authenticating in [true, false] {
        let (_relay, relay_url) = write_gated().await;
        let front = RecordingFront::start(&relay_url);
        let manager = RelayManager::new();
        let (transport, event) = if authenticating {
            let ceiling = haven_core::relay::AUTH_RETRY_MS / 1_000;
            (
                manager
                    .fanout_transport()
                    .authenticating(Arc::clone(&signer)),
                location_expiring_in(ceiling - 1),
            )
        } else {
            (manager.fanout_transport(), location_expiring_in(228))
        };
        let sent = within(
            "the location send",
            transport.publish_location(&event, &[front.url().to_owned()]),
        )
        .await;
        assert!(
            matches!(sent, Err(RelayError::AllRelaysFailed)),
            "authenticating={authenticating}: a location no relay took was reported sent",
        );
        assert!(
            authenticated_connections(&front).is_empty(),
            "authenticating={authenticating}: a resend was made that could have ended past \
             the location's expiration, or by a transport that holds no identity",
        );
        assert_eq!(events(&front).len(), 1, "more than one attempt was made");
    }
}
