//! The one place a relay client is built, and the check every relay event
//! passes before anything acts on it.
//!
//! `nostr-relay-pool` 0.44.3 skips verification for an event whose CLAIMED id
//! it has verified before (`SharedState::verify_and_cache`), so a relay that
//! replays a seen id over another author, other content or another signature
//! is believed. [`VerifiedEvents`] runs in the pool's admission hook: after
//! that cache, and before the pool's database, its id-keyed stream
//! de-duplication and every notification. A forgery therefore reaches no
//! consumer and cannot displace the genuine event whose id it borrows — which
//! a check made after the pool's de-duplication could not promise. Tracker
//! `T-POOL-VERIFY-CACHE`; guarded by `scripts/ci/check_engine_client_options.sh`.

use nostr::util::BoxedFuture;
use nostr::{Event, RelayUrl, SubscriptionId};
use nostr_sdk::pool::monitor::Monitor;
use nostr_sdk::pool::policy::{AdmitPolicy, AdmitStatus, PolicyError};
use nostr_sdk::{Client, ClientOptions};

/// Admits a relay event only when its id is the hash of its fields and its
/// signature is its author's over that id.
///
/// It logs nothing and gives no reason: it runs once per frame a relay chooses
/// to send, and whatever it rendered would be relay-chosen (Security Rule 15).
/// A refused event is dropped as if the relay had withheld it.
#[derive(Debug)]
struct VerifiedEvents;

impl AdmitPolicy for VerifiedEvents {
    fn admit_event<'a>(
        &'a self,
        _relay_url: &'a RelayUrl,
        _subscription_id: &'a SubscriptionId,
        event: &'a Event,
    ) -> BoxedFuture<'a, Result<AdmitStatus, PolicyError>> {
        // `verify`, never `verify_signature`: a signature covers the claimed id
        // alone, so it still holds over fields swapped under a genuine id.
        let status = if event.verify().is_ok() {
            AdmitStatus::Success
        } else {
            AdmitStatus::Rejected { reason: None }
        };
        Box::pin(async move { Ok(status) })
    }
}

/// Builds a relay client that hands on only verified events.
///
/// Every `Client` Haven reads a relay with is built here, so none can be built
/// without the check. Reachable from `crate::relay` only: the module is private.
///
/// And none can be built that answers a relay's NIP-42 challenge: whatever
/// `opts` says, authentication is switched off here. The SDK's default is ON,
/// and an answer is the identity key's signature over a relay's challenge on a
/// socket that carries a circle's routing id.
pub fn verified_client(opts: ClientOptions, monitor: Option<Monitor>) -> Client {
    let builder = Client::builder()
        .opts(opts.automatic_authentication(false))
        .admit_policy(VerifiedEvents);
    match monitor {
        Some(monitor) => builder.monitor(monitor),
        None => builder,
    }
    .build()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use nostr::secp256k1::schnorr::Signature;
    use nostr::secp256k1::Message;
    use nostr::{EventBuilder, Filter, JsonUtil as _, Keys, Kind, Tag, Timestamp};
    use nostr_sdk::RelayPoolOptions;

    use super::*;
    use crate::relay::scripted_relay::{Frame, ScriptedRelay};

    fn note(keys: &Keys, content: &str) -> Event {
        EventBuilder::text_note(content)
            .sign_with_keys(keys)
            .expect("a locally built event signs")
    }

    /// The SDK answers a relay's NIP-42 challenge unless told not to. No
    /// caller can build a relay client that does, by leaving the option out.
    #[test]
    fn a_client_built_here_never_answers_a_nip42_challenge_whatever_it_was_asked() {
        let client = verified_client(ClientOptions::default(), None);
        assert!(
            !client.pool().state().is_auto_authentication_enabled(),
            "a relay client built with the SDK's own options would sign a \
             relay's challenge with whatever signer it is ever given",
        );
    }

    /// The forgeries a relay can make of `genuine` without its author's key,
    /// each under `genuine`'s id: other content, another author — unsigned,
    /// and validly signed by a key of the relay's own over the borrowed id —
    /// another signature, another timestamp, another tag.
    fn forgeries_of(genuine: &Event) -> Vec<(&'static str, Event)> {
        let mut content = genuine.clone();
        content.content = "forged".to_string();
        let mut author = genuine.clone();
        author.pubkey = Keys::generate().public_key();
        author.sig = Signature::from_slice(&[7; 64]).expect("any 64 bytes parse as a signature");
        let attacker = Keys::generate();
        let mut signing_author = genuine.clone();
        signing_author.pubkey = attacker.public_key();
        signing_author.sig = attacker.sign_schnorr(&Message::from_digest(genuine.id.to_bytes()));
        assert!(
            signing_author.verify_signature() && !signing_author.verify_id(),
            "the shape: a valid signature over an id the fields do not hash to"
        );
        let mut signature = genuine.clone();
        signature.sig = note(&Keys::generate(), "another event").sig;
        let mut created_at = genuine.clone();
        created_at.created_at = Timestamp::from(genuine.created_at.as_secs() + 1);
        let mut tag = genuine.clone();
        tag.tags.push(Tag::hashtag("forged"));
        vec![
            ("content", content),
            ("author", author),
            ("signing author", signing_author),
            ("signature", signature),
            ("created_at", created_at),
            ("tag", tag),
        ]
    }

    async fn admitted(event: &Event) -> AdmitStatus {
        let relay = RelayUrl::parse("wss://relay.example.com").expect("a relay url");
        VerifiedEvents
            .admit_event(&relay, &SubscriptionId::new("sub"), event)
            .await
            .expect("the policy has no failure of its own")
    }

    #[tokio::test]
    async fn the_policy_admits_a_genuine_event_and_refuses_every_forgery_of_it() {
        let genuine = note(&Keys::generate(), "genuine");
        assert_eq!(admitted(&genuine).await, AdmitStatus::Success);
        for (shape, forged) in forgeries_of(&genuine) {
            assert!(forged.id == genuine.id, "{shape}: a forgery borrows the id");
            assert_eq!(
                admitted(&forged).await,
                AdmitStatus::Rejected { reason: None },
                "a {shape} forgery was admitted, or was refused with words"
            );
        }
    }

    /// The two callers differ only in what they pass here, so both must reach
    /// the client: the engine's options and its monitor, the publish client's
    /// defaults and none.
    #[tokio::test]
    async fn the_constructor_hands_on_the_callers_options_and_monitor() {
        let one_relay = RelayPoolOptions::default().max_relays(Some(1));
        let client = verified_client(
            ClientOptions::default().pool(one_relay),
            Some(Monitor::new(1)),
        );
        assert!(client.monitor().is_some(), "the monitor was dropped");
        // Registered, never dialled: nothing here connects.
        client
            .add_relay("ws://127.0.0.1:1")
            .await
            .expect("the first relay fits");
        assert!(
            client.add_relay("ws://127.0.0.1:2").await.is_err(),
            "the options were dropped: the pool took a relay past its limit"
        );

        let plain = verified_client(ClientOptions::default(), None);
        assert!(plain.monitor().is_none(), "a monitor nobody asked for");
    }

    /// What `client` gets back from a relay that first shows it `genuine` under
    /// a subscription nobody opened, and then answers the fetch with `forged`
    /// followed by `genuine`.
    async fn fetched(client: &Client, genuine: &Event, forged: &Event) -> Vec<Event> {
        let relay = ScriptedRelay::start();
        relay.answer(
            |_| true,
            vec![
                Frame::Unasked(genuine.clone()),
                Frame::Event(forged.clone()),
                Frame::Event(genuine.clone()),
                Frame::Eose,
            ],
        );
        client.add_relay(relay.url()).await.expect("add the relay");
        client.connect().await;
        let events = client
            .fetch_events_from(
                [relay.url()],
                Filter::new().kind(Kind::TextNote),
                Duration::from_secs(30),
            )
            .await
            .expect("the fetch completes on the relay's EOSE");
        client.shutdown().await;
        events.into_iter().collect()
    }

    /// The reason this module exists, kept as a test so it goes red the day the
    /// pool closes the shortcut itself (tracker `T-POOL-VERIFY-CACHE`'s removal
    /// signal): a client with no policy hands back all three forgeries.
    #[tokio::test]
    async fn a_pool_client_without_the_policy_hands_back_a_forgery_of_an_id_it_has_seen() {
        let genuine = note(&Keys::generate(), "genuine");
        for (shape, forged) in forgeries_of(&genuine) {
            let events = fetched(&Client::builder().build(), &genuine, &forged).await;
            assert!(
                events == [forged],
                "the pool refused a {shape} forgery on its own, or let the \
                 genuine event through beside it: the shortcut this policy \
                 covers has changed upstream"
            );
        }
    }

    #[tokio::test]
    async fn the_verified_client_drops_the_forgery_and_keeps_the_genuine_event_behind_it() {
        let genuine = note(&Keys::generate(), "genuine");
        for (shape, forged) in forgeries_of(&genuine) {
            let client = verified_client(ClientOptions::default(), None);
            assert!(
                fetched(&client, &genuine, &forged).await == std::slice::from_ref(&genuine),
                "a {shape} forgery got through, or took the genuine event's place"
            );
        }
    }

    /// The check is over the event, not over its spelling. A relay may send a
    /// genuine event with its keys in another order, a field NIP-01 does not
    /// name, and `/` escaped; the id is recomputed from the parsed fields, so
    /// it is admitted, and what arrives is the event its author signed.
    #[tokio::test]
    async fn a_genuine_event_spelled_another_way_on_the_wire_is_admitted_unchanged() {
        let genuine = EventBuilder::text_note("https://example.com/a")
            .tag(Tag::parse(["r", "wss://relay.example.com/"]).expect("a tag"))
            .sign_with_keys(&Keys::generate())
            .expect("a locally built event signs");
        let field = |name: &str| {
            serde_json::to_string(&serde_json::to_value(&genuine).expect("event json")[name])
                .expect("a field")
                .replace('/', r"\/")
        };
        let respelled = format!(
            r#"{{"sig":{},"content":{},"seen_on":["wss:\/\/elsewhere.example.com"],"tags":{},"kind":{},"created_at":{},"pubkey":{},"id":{}}}"#,
            field("sig"),
            field("content"),
            field("tags"),
            field("kind"),
            field("created_at"),
            field("pubkey"),
            field("id"),
        );
        assert!(
            respelled.contains(r"https:\/\/example.com\/a") && respelled != genuine.as_json(),
            "the wire text is not the canonical spelling"
        );

        let relay = ScriptedRelay::start();
        relay.answer(|_| true, vec![Frame::Raw(respelled), Frame::Eose]);
        let client = verified_client(ClientOptions::default(), None);
        client.add_relay(relay.url()).await.expect("add the relay");
        client.connect().await;
        let events = client
            .fetch_events_from(
                [relay.url()],
                Filter::new().kind(Kind::TextNote),
                Duration::from_secs(30),
            )
            .await
            .expect("the fetch completes on the relay's EOSE");
        client.shutdown().await;
        assert!(
            events.into_iter().collect::<Vec<_>>() == [genuine],
            "a genuine event in another JSON spelling was refused, or changed"
        );
    }
}
