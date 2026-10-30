//! What Haven's fanout transport returns about ONE relay, for every way a
//! relay can answer a publish — MDK's relay client on the publish pool, against
//! an in-process relay, and against a real one for NIP-42.
//!
//! This is the table the durable fanout's decisions are read from. `Accepted`
//! confirms. Two answers count towards "every relay proved it did not accept":
//! `TerminalRejected`, which the transport returns only when the relay's own
//! `OK` frames show it refused EVERY attempt MDK's client made in the call, and
//! `NotExposed`, Haven's own refusal before anything was handed over. Nothing
//! else may ever count towards rolling a commit back. Each case also records
//! how many `EVENT` frames the relay was sent in the one call, which is MDK's
//! to decide (`transport-nostr-adapter/src/sdk_client.rs` 733-790, v0.10.4).
//!
//! Four cases wait on timers nobody here can inject — the pool's 10 s wait for
//! an `OK` and the adapter's 20 s ceiling (`sdk_client.rs` 36-49). Their
//! outcome is fixed; only how long it takes is real: about 20 s each for the
//! withheld `OK` and the dropped socket, about 11 s for each of the two
//! timeouts that are then refused. Every other case is answered at once and
//! pays at most two 600 ms adapter backoffs.

mod cargo_graph;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use haven_core::nostr::mls::types::{
    TransportEndpointFailureKind, TransportEndpointRejectionCategory, TransportMessage,
};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::FanoutTargetOutcome;
use haven_core::relay::scripted_relay::{ScriptedRelay, Verdict};
use haven_core::relay::RelayManager;
use nostr::{EventBuilder, Filter, Keys, Kind, Tag};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::LocalRelay;
use nostr_sdk::{Client, ClientOptions};

/// A signed kind-445 event in the shape the engine's are, as the transport
/// message a fanout row freezes.
fn fanout_message() -> TransportMessage {
    fanout_message_signed_at(nostr::Timestamp::now())
}

/// [`fanout_message`], signed at `at`: a recorded commit sent again hours
/// after it was signed carries the instant it was signed.
fn fanout_message_signed_at(at: nostr::Timestamp) -> TransportMessage {
    let event = EventBuilder::new(Kind::Custom(445), "ciphertext")
        .tag(Tag::parse(["h", &"ab".repeat(32)]).expect("an h tag"))
        .custom_created_at(at)
        .sign_with_keys(&Keys::generate())
        .expect("a locally built event signs");
    SessionManager::event_to_transport_message(&event).expect("a kind-445 event converts")
}

async fn publish(target: &str, message: &TransportMessage) -> FanoutTargetOutcome {
    publish_through(&RelayManager::new(), target, message).await
}

/// [`publish`] through `manager`'s transport.
async fn publish_through(
    manager: &RelayManager,
    target: &str,
    message: &TransportMessage,
) -> FanoutTargetOutcome {
    let transport = manager.fanout_transport();
    let taken = transport.take(target).await.expect("the relay is free");
    transport.publish(target, message, taken).await
}

/// One publish to a relay that answers every `EVENT` with `OK false` and
/// `text`: the outcome, and how many frames the relay was sent.
async fn refused_with(text: &'static str) -> (FanoutTargetOutcome, usize) {
    let relay = ScriptedRelay::start();
    relay.on_publish(move |_| Verdict::Refuse(text.to_string()));
    let outcome = publish(relay.url(), &fanout_message()).await;
    assert!(
        relay.published().is_empty(),
        "a refusing relay keeps nothing"
    );
    (outcome, relay.offers())
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

/// A machine-readable refusal that proves the relay did not take the event.
async fn assert_terminal(text: &'static str, category: TransportEndpointRejectionCategory) {
    let (outcome, frames) = refused_with(text).await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::TerminalRejected,
                Some(category)
            )),
        "this prefix is no longer a proven rejection in its own category",
    );
    // MDK's client re-sends after a classified refusal too; T-ADAPTER-ATTEMPTS.
    assert!(
        frames == 3,
        "the frames sent to a relay that refused have changed"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ok_true_is_accepted_on_one_frame() {
    let relay = ScriptedRelay::start();
    let message = fanout_message();
    let outcome = publish(relay.url(), &message).await;

    assert!(matches!(outcome, FanoutTargetOutcome::Accepted));
    assert!(relay.offers() == 1, "an accepted publish is one frame");
    let published = relay.published();
    assert!(
        published.len() == 1
            && published[0].id.as_bytes() == message.id.as_slice()
            && published[0].verify().is_ok(),
        "the relay holds some other event than the frozen, signed one",
    );
}

/// The conformant wire form of a redrive: the relay already holds the event
/// and says so with `OK true`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_true_saying_duplicate_is_accepted() {
    let relay = ScriptedRelay::start();
    relay.on_publish(|_| Verdict::KeepSaying("duplicate: already have this event".to_string()));
    let outcome = publish(relay.url(), &fanout_message()).await;
    assert!(matches!(outcome, FanoutTargetOutcome::Accepted));
    assert!(relay.offers() == 1, "an acceptance ends the call");
}

/// An `OK true` that names some other event acknowledges nothing: the relay
/// says it first, then refuses the event it was sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_true_for_another_event_is_no_acknowledgement() {
    let relay = ScriptedRelay::start();
    let other = fanout_message();
    let other_id = hex::encode(other.id.as_slice());
    relay.on_publish(move |event| {
        Verdict::Frames(vec![
            serde_json::json!(["OK", other_id, true, ""]).to_string(),
            serde_json::json!(["OK", event.id, false, "blocked: not this one"]).to_string(),
        ])
    });
    let outcome = publish(relay.url(), &fanout_message()).await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::Blocked)
            )),
        "an acknowledgement of some other event was taken for this one",
    );
}

/// `duplicate:` is `OK false`, and it means the relay already holds the event.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_duplicate_is_accepted() {
    let (outcome, frames) = refused_with("duplicate: already have this event").await;
    assert!(matches!(outcome, FanoutTargetOutcome::Accepted));
    assert!(frames == 1, "an acceptance ends the call");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_blocked_is_a_terminal_rejection() {
    assert_terminal(
        "blocked: you are not allowed here",
        TransportEndpointRejectionCategory::Blocked,
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_pow_is_a_terminal_rejection() {
    assert_terminal(
        "pow: difficulty 28 is required",
        TransportEndpointRejectionCategory::Pow,
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_unsupported_is_a_terminal_rejection() {
    assert_terminal(
        "unsupported: this kind is not stored here",
        TransportEndpointRejectionCategory::Unsupported,
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_restricted_is_a_terminal_rejection() {
    assert_terminal(
        "restricted: members only",
        TransportEndpointRejectionCategory::Restricted,
    )
    .await;
}

/// A relay that refuses an event for its timestamp says `invalid:`. MDK's
/// client keeps the category and drops the relay's words, so the fanout sees an
/// ordinary proven rejection and Haven's clock classifier has nothing to read:
/// the device-clock verdict stays with the location path (T-CLOCK-SKEW).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_clock_skew_rejection_is_a_terminal_invalid_with_no_relay_text() {
    const RELAY_TEXT: &str = "invalid: event creation date is too far off from the current time";
    assert!(
        haven_core::relay::classify_relay_rejection(RELAY_TEXT).is_some(),
        "the relay's text has to be one Haven's clock classifier knows, or \
         this case shows nothing about what the fanout loses",
    );
    let (outcome, _) = refused_with(RELAY_TEXT).await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::Invalid)
            )),
        "a timestamp refusal is no longer an ordinary proven rejection",
    );
    assert!(
        !format!("{outcome:?}").contains("creation date"),
        "the relay's text came through the transport",
    );
}

/// `rate-limited:` proves nothing was stored and asks for a later attempt.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_rate_limited_is_retryable_unavailable() {
    let (outcome, frames) = refused_with("rate-limited: slow down").await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::RetryableUnavailable,
                Some(TransportEndpointRejectionCategory::RateLimited)
            )),
        "a rate limit was classified as exposure, or as a refusal of the event",
    );
    // Inside the one call MDK's client does not back off a relay that asked it
    // to: three frames, 600 ms apart. Recorded in T-ADAPTER-ATTEMPTS.
    assert!(
        frames == 3,
        "the frames sent to a rate-limiting relay have changed"
    );
}

/// The publish client holds no signer and never authenticates, so `auth-required:`
/// is an answer that cannot change: a refusal of the event, proven on every
/// attempt. Retrying it would only hand a relay that will not take the event
/// the device's address again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_auth_required_is_a_terminal_rejection() {
    let (outcome, frames) = refused_with("auth-required: we only accept events from members").await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::AuthRequired)
            )),
        "a demand this client can never meet was left retryable",
    );
    assert!(
        frames == 3,
        "the frames sent to a relay that wants AUTH have changed"
    );
}

/// `error:` is also what the SDK calls its own send failures, so it proves
/// nothing about the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_error_is_possibly_exposed() {
    let (outcome, _) = refused_with("error: could not connect to the database").await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::PossiblyExposed,
                Some(TransportEndpointRejectionCategory::Error)
            )),
        "`error:` was taken as proof the relay does not hold the event",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ok_false_with_no_prefix_is_possibly_exposed() {
    let (outcome, _) = refused_with("go away").await;
    assert!(
        classified(&outcome) == Some((TransportEndpointFailureKind::PossiblyExposed, None)),
        "a refusal no machine can read was taken as proof of anything",
    );
}

/// The relay stores the event and its `OK` never arrives. About 20 s: the
/// pool's wait for the `OK`, a second attempt, and the adapter's ceiling.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_event_whose_ok_is_withheld_is_possibly_exposed() {
    let relay = ScriptedRelay::start();
    relay.on_publish(|_| Verdict::KeepSilently);
    let message = fanout_message();
    let outcome = publish(relay.url(), &message).await;

    assert!(
        classified(&outcome) == Some((TransportEndpointFailureKind::PossiblyExposed, None)),
        "a publish the relay holds was classified as something a rollback \
         could act on",
    );
    assert!(
        relay
            .published()
            .iter()
            .any(|event| event.id.as_bytes() == message.id.as_slice()),
        "the relay does hold the event: that is the case",
    );
}

/// Nothing listens on the port, so no byte of the event left the device.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_connection_is_retryable_unavailable() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    // Bound and never listening: the port is held for the whole test, and the
    // kernel refuses every connection to it.
    let held = tokio::net::TcpSocket::new_v4().expect("a socket");
    held.bind("127.0.0.1:0".parse().expect("a loopback address"))
        .expect("bind a loopback port");
    let port = held.local_addr().expect("the bound address").port();

    let outcome = publish(&format!("ws://127.0.0.1:{port}"), &fanout_message()).await;
    assert!(
        classified(&outcome) == Some((TransportEndpointFailureKind::RetryableUnavailable, None)),
        "a relay that could not be reached was classified as exposed, or as \
         a refusal",
    );
}

/// The relay reads the event and closes the socket without a word. About
/// 20 s: the pool waits out its `OK` window on the closed socket, and the
/// adapter's ceiling ends the second attempt.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_socket_dropped_after_the_send_is_possibly_exposed() {
    let relay = ScriptedRelay::start();
    relay.on_publish(|_| Verdict::HangUp);
    let outcome = publish(relay.url(), &fanout_message()).await;

    assert!(relay.offers() >= 1, "the relay was sent the event");
    assert!(
        classified(&outcome) == Some((TransportEndpointFailureKind::PossiblyExposed, None)),
        "an event a relay read before it hung up was classified as not sent",
    );
}

/// One publish to a relay that stores the first attempt in silence and answers
/// every later one `OK false` with `text`: MDK's client reports its LAST
/// attempt, a relay-spoken refusal of an event the relay holds.
///
/// About 11 s: the pool's 10 s wait for the first `OK`, then two refusals.
async fn stored_then_refused_with(text: &'static str) -> FanoutTargetOutcome {
    let relay = ScriptedRelay::start();
    let offered = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&offered);
    relay.on_publish(move |_| {
        if counter.fetch_add(1, Ordering::SeqCst) == 0 {
            Verdict::KeepSilently
        } else {
            Verdict::Refuse(text.to_string())
        }
    });
    let message = fanout_message();
    let outcome = publish(relay.url(), &message).await;
    assert!(
        relay
            .published()
            .iter()
            .any(|event| event.id.as_bytes() == message.id.as_slice()),
        "the relay stored the first attempt: that is the case",
    );
    assert!(relay.offers() == 3, "MDK's client made its three attempts");
    outcome
}

/// A refusal is a relay's only when the relay answered EVERY attempt with one.
/// Here the first attempt was stored and never answered, so two `blocked:`
/// answers prove nothing about it: the event may be held, and a commit a relay
/// may hold is never rolled back (Security Rule 13).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_timeout_then_blocked_inside_one_call_is_possibly_exposed() {
    let outcome = stored_then_refused_with("blocked: not any more").await;
    assert!(
        matches!(
            classified(&outcome),
            Some((TransportEndpointFailureKind::PossiblyExposed, _))
        ),
        "a refusal that followed an unanswered attempt was returned as proof \
         the relay does not hold the event",
    );
}

/// The same masking one class down: `rate-limited:` after an unanswered attempt
/// would read as "nothing was stored, try later", which the never-exposed
/// bound may roll back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_timeout_then_rate_limited_inside_one_call_is_possibly_exposed() {
    let outcome = stored_then_refused_with("rate-limited: slow down").await;
    assert!(
        matches!(
            classified(&outcome),
            Some((TransportEndpointFailureKind::PossiblyExposed, _))
        ),
        "a rate limit that followed an unanswered attempt was returned as \
         proof nothing was stored",
    );
}

/// What Haven itself refuses before anything is handed to MDK's client is not
/// exposed, and says so: a row whose only answer were "possibly exposed" could
/// never end.
fn assert_not_exposed(outcome: &FanoutTargetOutcome, relay: &ScriptedRelay) {
    assert!(
        classified(outcome) == Some((TransportEndpointFailureKind::NotExposed, None)),
        "something Haven refused to hand over was not classified as unexposed",
    );
    assert!(relay.offers() == 0, "what Haven refused reached a relay");
    assert!(
        relay.connections() == 0,
        "what Haven refused got a relay dialled"
    );
}

/// The frozen bytes are sent only as the signed event they are: one whose
/// signature does not verify is not handed over.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_event_whose_signature_does_not_verify_is_never_handed_over() {
    let relay = ScriptedRelay::start();
    let mut forged = fanout_message();
    let borrowed: serde_json::Value =
        serde_json::from_slice(&fanout_message().payload).expect("event json");
    let mut event: serde_json::Value = serde_json::from_slice(&forged.payload).expect("event json");
    event["sig"] = borrowed["sig"].clone();
    forged.payload = serde_json::to_vec(&event).expect("event json");

    assert_not_exposed(&publish(relay.url(), &forged).await, &relay);
}

/// The transport sends signed bytes and signs nothing. An event that arrives
/// unsigned is refused by Haven, before MDK's client — which signs an unsigned
/// event with whatever signer the client it holds has — ever sees it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unsigned_event_is_never_handed_over() {
    let relay = ScriptedRelay::start();
    let mut unsigned = fanout_message();
    let mut event: serde_json::Value =
        serde_json::from_slice(&unsigned.payload).expect("event json");
    let fields = event.as_object_mut().expect("an event object");
    fields.remove("sig");
    // A gift wrap's kind: the one MDK's client would sign.
    fields.insert("kind".to_string(), serde_json::json!(1059));
    unsigned.payload = serde_json::to_vec(&event).expect("event json");

    assert_not_exposed(&publish(relay.url(), &unsigned).await, &relay);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_payload_that_is_not_an_event_is_never_handed_over() {
    let relay = ScriptedRelay::start();
    let mut message = fanout_message();
    message.payload = b"not an event".to_vec();

    assert_not_exposed(&publish(relay.url(), &message).await, &relay);
}

/// The first fact "can never authenticate" rests on, against a real relay that
/// demands NIP-42 authentication to write: Haven's publish is refused on every
/// attempt and the relay keeps nothing — while a client that holds a key and
/// answers the challenge gets the SAME event stored, so the refusal was the
/// missing authentication and nothing else.
///
/// Answering would sign a relay's challenge with a key: on this client, the
/// only key there could ever be is the identity key, bound by that signature
/// to the group's routing id, the device's address and the time.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_publish_client_never_answers_a_nip42_challenge() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Write,
    }));
    relay.run().await.expect("the auth relay runs");
    let url = relay.url().await.to_string();
    let message = fanout_message();
    let event = SessionManager::transport_message_to_event(&message).expect("the frozen event");

    let outcome = publish(&url, &message).await;
    assert!(
        classified(&outcome)
            == Some((
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::AuthRequired)
            )),
        "the publish client was not refused for want of authentication: it \
         answered the challenge, or the relay never issued one",
    );

    let control = Client::builder()
        .signer(Keys::generate())
        .opts(ClientOptions::default().automatic_authentication(true))
        .build();
    control.add_relay(&url).await.expect("add the relay");
    control.connect().await;
    assert!(
        held_copies(&control, &url, event.id).await == 0,
        "the relay kept an event from a client that never authenticated",
    );
    let sent = control
        .send_event_to([url.clone()], &event)
        .await
        .expect("the control's publish completes");
    assert!(
        sent.success.len() == 1 && held_copies(&control, &url, event.id).await == 1,
        "the relay refused the same event from a client that DID authenticate: \
         the refusal above was not about authentication, so it proves nothing",
    );
    control.shutdown().await;
}

/// How many events with `id` the relay at `url` serves `client`.
async fn held_copies(client: &Client, url: &str, id: nostr::EventId) -> usize {
    client
        .fetch_events_from(
            [url],
            Filter::new().id(id),
            std::time::Duration::from_secs(30),
        )
        .await
        .expect("the fetch completes on the relay's EOSE")
        .len()
}

/// `file` of the MDK crate `package`, from the checkout cargo resolved for
/// this crate.
fn mdk_source(package: &str, file: &str) -> String {
    let metadata = cargo_graph::host_metadata();
    let manifest = metadata["packages"]
        .as_array()
        .expect("packages")
        .iter()
        .find(|candidate| candidate["name"] == package)
        .and_then(|candidate| candidate["manifest_path"].as_str())
        .expect("the crate is in the graph");
    std::fs::read_to_string(std::path::Path::new(manifest).with_file_name(file))
        .expect("read MDK's source")
}

/// The cargo checkout of MDK's Nostr adapter this crate links.
fn mdk_relay_client_source() -> String {
    mdk_source("transport-nostr-adapter", "src/sdk_client.rs")
}

/// The driver tells an attempt that never ran to an answer from one a relay
/// answered by the text of the failure it stored for it: MDK's record has no
/// status for the first. That reading is sound only while nothing a relay
/// says can end up in that text. At this pin every reason MDK's relay client
/// writes is a fixed string, or a fixed string around the name of one of its
/// own rejection categories; none is the driver's marker. An MDK bump that
/// writes a reason any other way fails here, and is re-read before it lands.
#[test]
fn every_failure_reason_mdks_relay_client_writes_is_fixed_and_none_is_the_drivers_marker() {
    let source = mdk_relay_client_source();
    let product = source
        .split("#[cfg(test)]\nmod tests {")
        .next()
        .expect("the file has a product half");
    assert!(
        product.len() < source.len(),
        "the test half was not cut off"
    );
    let written: Vec<&str> = product
        .lines()
        .map(str::trim)
        .filter(|line| {
            line.starts_with("reason") || line.contains(".reason = ") || line.contains("let reason")
        })
        .collect();
    assert_eq!(
        written,
        [
            r#"reason: "connect relay failed".to_owned(),"#,
            r#"reason: "send event failed".to_owned(),"#,
            r#"last_failure.reason = "relay did not acknowledge event".to_owned();"#,
            r#"last_failure.reason = "send event failed".to_owned();"#,
            r#"last_failure.reason = "send event timed out".to_owned();"#,
            r#"reason: "configure publish relay failed".to_owned(),"#,
            r#"reason: "add publish relay failed".to_owned(),"#,
            // The whole call's summary, which is no target's stored reason.
            "let reason = if timed_out {",
            r#"reason: "publish acknowledgement unknown".into(),"#,
            "let reason = if kind == TransportEndpointFailureKind::PossiblyExposed {",
            "reason,",
            r#"reason: "publish acknowledgement unknown".to_owned(),"#,
        ],
        "MDK's relay client writes a failure reason this gate has not read",
    );
    // The one reason that is not a literal: a literal around a category name.
    assert!(
        product.contains(
            r#"let reason = if kind == TransportEndpointFailureKind::PossiblyExposed {
            "publish acknowledgement unknown (error)".to_owned()
        } else {
            format!("relay rejected event ({})", category.as_str())
        };"#
        ),
        "the reason of a relay's rejection is no longer built from a category name alone",
    );
    assert!(
        mdk_source("cgka-traits", "src/transport_adapter.rs").contains(
            "impl TransportEndpointRejectionCategory {\n    pub fn as_str(self) -> &'static str {"
        ),
        "a rejection category's name is no longer a fixed string",
    );
    let marker = haven_core::relay::fanout::INTERRUPTED;
    for literal in product.split('"').skip(1).step_by(2) {
        assert_ne!(literal, marker, "MDK writes the driver's own marker");
    }
    assert!(!"relay rejected event ()".contains(marker));
}

/// Why an invite's Welcomes can be released by a confirm alone, and what
/// that rests on at this pin — three things in three codebases, none of
/// which an API promises:
///
/// * MDK stages a plain invite with `OpenMLS`'s `add_members`, whose commit
///   carries an `UpdatePath`; only an invite that also grants an admin is
///   built without one;
/// * Haven's invite grants no admin, anywhere;
/// * the `OpenMLS` fork refuses to stage an own commit that carries a path
///   and is not the pending one, so the engine cannot apply such a commit
///   from its own stored row — a commit WITHOUT a path it can
///   (`docs/MDK_UPSTREAM_TRACKER.md` T-ROLLBACK-RESURRECT).
///
/// Were any of them to change, an invite could be applied with its Welcomes
/// never promoted: the invitee on the roster with no way in.
#[test]
fn an_invites_commit_is_applied_only_through_a_confirm_at_this_pin() {
    let send = mdk_source("cgka-engine", "src/message_processor/send.rs");
    assert!(
        send.contains(
            "let (commit_out, welcome_out) = if granted_admin_ids.is_empty() {
            let (commit_out, welcome_out, _gi) = mls_group
                .add_members(&provider, &self.identity.signer, &parsed_kps)"
        ),
        "MDK no longer stages an invite that grants no admin with `add_members`",
    );
    let fork = mdk_source("openmls", "src/group/mls_group/processing.rs");
    assert!(
        fork.contains(
            "if is_own_commit && commit.path.is_some() {
                    return Err(StageCommitError::OwnCommitMismatch.into());
                }"
        ),
        "the fork no longer refuses an own commit that carries a path",
    );
    let membership = mdk_source("openmls", "src/group/mls_group/membership.rs");
    assert!(
        membership.contains("self.add_members_internal(provider, signer, key_packages, true)"),
        "`add_members` no longer forces the path its commit is refused by",
    );
    // An invite is built wherever `SendIntent::Invite` is followed by its
    // fields rather than matched: each such place grants no admin.
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the repository");
    let mut built = 0;
    for dir in ["haven-core/src", "haven/rust_builder/src"] {
        let mut files = vec![root.join(dir)];
        while let Some(path) = files.pop() {
            if path.is_dir() {
                files.extend(
                    std::fs::read_dir(&path)
                        .expect("read a source directory")
                        .map(|entry| entry.expect("a directory entry").path()),
                );
                continue;
            }
            if path.extension().and_then(|extension| extension.to_str()) != Some("rs") {
                continue;
            }
            let source = std::fs::read_to_string(&path).expect("read Haven's source");
            for (at, _) in source.match_indices("SendIntent::Invite {") {
                let fields: String = source[at..]
                    .chars()
                    .take_while(|c| *c != '}')
                    .filter(|c| !c.is_whitespace())
                    .collect();
                if fields.contains("..") {
                    continue;
                }
                built += 1;
                assert!(
                    fields.contains("initial_admins:Vec::new(),"),
                    "{}: an invite grants an admin",
                    path.display()
                );
            }
        }
    }
    assert_eq!(built, 1, "Haven builds its invite in one place");
}

/// The transport proves a refusal by counting the relay's answers against the
/// number of attempts MDK's client makes inside one call. That number is a
/// private constant of MDK's; this reads it from the source cargo resolved.
#[test]
fn mdks_in_call_attempt_count_is_the_one_the_transport_counts_against() {
    let source = mdk_relay_client_source();
    assert!(
        source.contains(&format!(
            "const SDK_RELAY_PUBLISH_ATTEMPTS: usize = {};",
            haven_core::relay::fanout::MDK_ATTEMPTS_PER_CALL
        )),
        "MDK's relay client no longer makes the number of attempts per call \
         the fanout transport requires an answer for. A lower count degrades \
         every refusal to possibly exposed; a higher one would let an \
         unanswered attempt pass as refused — never bump MDK with this test red",
    );
    assert!(
        source.contains("for attempt in 1..=SDK_RELAY_PUBLISH_ATTEMPTS"),
        "the constant no longer drives the loop it was read for",
    );
}

/// A drive waits for every relay it called, and a relay that never answers
/// costs it MDK's own ceiling for one call. That is a private constant of
/// MDK's; what Haven says of it — and what the soak lane prices a withheld
/// acknowledgement at — is read from the source cargo resolved.
#[test]
fn mdks_call_ceiling_is_the_one_a_drive_is_said_to_wait() {
    assert!(
        mdk_relay_client_source().contains(&format!(
            "const SDK_RELAY_PUBLISH_OVERALL_WAIT: Duration = Duration::from_secs({});",
            haven_core::relay::fanout::MDK_CALL_CEILING_SECS
        )),
        "MDK's relay client no longer gives up on one call after the time \
         Haven documents and the soak lane budgets for",
    );
}

/// Security Rule 16 rests on MDK's relay client building no client of its own
/// and installing nothing on the one it is handed. MDK does not enforce that;
/// this re-reads its source on every run, so an MDK bump that changes it fails
/// here rather than passing review unread.
#[test]
fn mdks_relay_client_builds_no_client_and_installs_nothing_on_the_one_it_is_handed() {
    let source = mdk_relay_client_source();
    let product = source
        .split("#[cfg(test)]\nmod tests {")
        .next()
        .expect("the file has a product half");
    assert!(
        product.len() < source.len() && product.contains("pub fn new(client: Client) -> Self"),
        "the scan is not reading the product half of MDK's relay client",
    );
    // The control: MDK's own tests, in the other half of this file, do build
    // clients with signers, so the scan below sees what it looks for.
    let tests = &source[product.len()..];
    assert!(
        tests.contains("Client::builder") && tests.contains(".signer("),
        "the scan would not recognise a client construction in this file",
    );
    for forbidden in [
        "Client::builder",
        "Client::new",
        "Client::default",
        "ClientBuilder",
        "RelayPool::",
        "Relay::new",
        "set_signer",
        ".signer(",
        "gossip",
        "admit_policy",
        "automatic_authentication",
    ] {
        assert!(
            !product.contains(forbidden),
            "MDK's relay client now names `{forbidden}` outside its tests: \
             re-read it against Security Rule 16 before trusting the client \
             it holds",
        );
    }
}

/// Khatru refuses an event older than its operator's window as `blocked:
/// event too old`, judging the event's age: a recorded commit sent again
/// hours after it was signed is no evidence of a slow clock, while a fresh
/// event refused as too old still is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refusal_of_an_old_resend_as_too_old_blames_no_clock() {
    use haven_core::relay::clock_skew::DeviceClockComplaint;
    // The age is read off the transport's clock alone, never the wall clock,
    // so no stall of the test can change it.
    const NOW: u64 = 1_700_000_000;
    let blamed_for = |signed_secs_ago: u64| async move {
        let relay = ScriptedRelay::start();
        relay.on_publish(|_| Verdict::Refuse("blocked: event too old".to_string()));
        let at = nostr::Timestamp::from(NOW - signed_secs_ago);
        match publish_through(
            &RelayManager::at_for_test(NOW),
            relay.url(),
            &fanout_message_signed_at(at),
        )
        .await
        {
            FanoutTargetOutcome::Accepted => panic!("a refusing relay took the event"),
            FanoutTargetOutcome::Failed(failure) => failure.clock_blamed(),
        }
    };
    assert_eq!(
        blamed_for(3 * 3600).await,
        None,
        "a re-send hours old, refused for its age, was read as a slow clock",
    );
    assert_eq!(
        blamed_for(0).await,
        Some(DeviceClockComplaint::Behind),
        "a fresh event refused as too old is no longer clock evidence",
    );
}

/// A relay's refusal that blames the event's timestamp is kept as clock
/// evidence beside the failure, classified and its words gone; any other
/// refusal blames nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refusal_blaming_the_timestamp_is_kept_as_clock_evidence() {
    use haven_core::relay::clock_skew::DeviceClockComplaint;
    let blamed = |outcome: &FanoutTargetOutcome| match outcome {
        FanoutTargetOutcome::Accepted => None,
        FanoutTargetOutcome::Failed(failure) => failure.clock_blamed(),
    };
    let (ahead, _) = refused_with("invalid: event creation date is in the future").await;
    let (behind, _) = refused_with("invalid: event is too old").await;
    let (other, _) = refused_with("blocked: not on the allow list").await;
    // khatru's timestamp policies answer under `blocked:`.
    let (khatru, _) = refused_with("blocked: event too much in the future").await;
    // A refusal under another prefix that mentions a timestamp is not a
    // clock complaint: only `invalid:`, `blocked:` or no prefix are.
    let (limited, _) = refused_with("rate-limited: too many events in the future").await;
    let (pow, _) = refused_with("pow: difficulty too low for an event in the past").await;
    let (bare, _) = refused_with("event created_at is in the future").await;
    assert_eq!(
        (
            blamed(&ahead),
            blamed(&behind),
            blamed(&other),
            blamed(&khatru),
            blamed(&limited),
            blamed(&pow),
            blamed(&bare)
        ),
        (
            Some(DeviceClockComplaint::Ahead),
            Some(DeviceClockComplaint::Behind),
            None,
            Some(DeviceClockComplaint::Ahead),
            None,
            None,
            Some(DeviceClockComplaint::Ahead)
        ),
        "a timestamp refusal was not kept as clock evidence, or another refusal was",
    );
}
