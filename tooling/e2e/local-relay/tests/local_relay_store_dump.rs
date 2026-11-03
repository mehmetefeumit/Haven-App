//! Pins how the in-memory relay answers a whole-store dump: the one REQ
//! `TestRelay.dumpStore` (`haven/integration_test/e2e/_lib/test_relay.dart`)
//! sends, `{"limit": 500}`, on the lanes that run this relay (the iOS profile
//! lane's circle relay and profile pool).
//!
//! `dumpStore` treats an answer of exactly its limit as possibly truncated and
//! refuses it, and treats `EOSE` as the end of the store. Both are sound only
//! if this relay serves at most the limit asked, then `EOSE` — never fewer
//! than it holds below the limit, and never a cap lower than the limit (which
//! would make a truncated dump read as complete). strfry's half is its
//! `maxFilterLimit = 500` (`tooling/e2e/strfry.conf`), pinned by the Dart
//! mirror test.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use haven_local_relay::loopback::start_local_relay;
use nostr_relay_builder::prelude::*;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

/// `TestRelay.kDumpStoreLimit`.
const DUMP_LIMIT: usize = 500;

/// Events one connection may publish inside the relay's per-session rate
/// limit (`RateLimit::default()`: 60 per minute).
const PER_CONNECTION: usize = 56;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(url: &str) -> Client {
    tokio_tungstenite::connect_async(url)
        .await
        .expect("connect to the local relay")
        .0
}

async fn next_frame(client: &mut Client) -> Value {
    loop {
        let message = tokio::time::timeout(Duration::from_secs(30), client.next())
            .await
            .expect("the relay answered within the bound")
            .expect("the relay kept the connection open")
            .expect("a readable message");
        if let Message::Text(text) = message {
            return serde_json::from_str(text.as_str()).expect("a JSON frame");
        }
    }
}

/// Publishes `count` distinct events, each acknowledged as stored.
async fn publish(url: &str, keys: &Keys, first: usize, count: usize) {
    let mut client = connect(url).await;
    for i in first..first + count {
        let event = EventBuilder::text_note(i.to_string())
            .sign_with_keys(keys)
            .expect("sign");
        client
            .send(Message::Text(
                serde_json::json!(["EVENT", event]).to_string().into(),
            ))
            .await
            .expect("send");
        let ok = next_frame(&mut client).await;
        assert_eq!(ok[0], "OK");
        assert_eq!(ok[2], true, "the relay stored every seeded event");
    }
    let _ = client.close(None).await;
}

/// The events one `{"limit": 500}` REQ returns before its `EOSE`.
async fn dump(url: &str) -> usize {
    let mut client = connect(url).await;
    client
        .send(Message::Text(
            serde_json::json!(["REQ", "dump", {"limit": DUMP_LIMIT}])
                .to_string()
                .into(),
        ))
        .await
        .expect("send");
    let mut events = 0;
    loop {
        let frame = next_frame(&mut client).await;
        match frame[0].as_str() {
            Some("EVENT") => events += 1,
            Some("EOSE") => break,
            _ => panic!("the dump got neither an event nor its EOSE"),
        }
    }
    let _ = client.close(None).await;
    events
}

#[tokio::test]
async fn a_store_dump_returns_everything_below_its_limit_and_exactly_the_limit_above_it() {
    let (_relay, url) = start_local_relay().await.expect("start the local relay");
    let keys = Keys::generate();

    publish(&url, &keys, 0, 3).await;
    assert_eq!(
        dump(&url).await,
        3,
        "below the limit the dump is the whole store, ended by EOSE"
    );

    let mut seeded = 3;
    while seeded <= DUMP_LIMIT {
        publish(&url, &keys, seeded, PER_CONNECTION).await;
        seeded += PER_CONNECTION;
    }
    assert_eq!(
        dump(&url).await,
        DUMP_LIMIT,
        "above the limit the dump is exactly the limit, so an answer of the \
         limit is the one shape that may hide a truncation"
    );
}
