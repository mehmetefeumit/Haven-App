//! `haven-fault-relay`'s modes and control verbs, each proved by the ORDER of
//! frames on one socket rather than by waiting: the backing relay answers one
//! connection's frames in the order it receives them, so "no `OK` came before
//! the `EOSE` of a later `REQ`" proves the event never reached it.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use haven_local_relay::fault::{FaultRelay, Mode, REFUSAL};
use nostr_relay_builder::prelude::{EventBuilder, Keys, Kind, Tag};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Bounds every read: an answer that never comes fails the test by name
/// instead of hanging it.
const ANSWER_BOUND: Duration = Duration::from_secs(30);

async fn start(mode: Mode) -> (FaultRelay, String) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let url = format!("ws://{}", listener.local_addr().expect("address"));
    (FaultRelay::start(listener, mode), url)
}

async fn connect(url: &str) -> Client {
    tokio_tungstenite::connect_async(url)
        .await
        .expect("connect to the fault relay")
        .0
}

async fn send(client: &mut Client, frame: &Value) {
    client
        .send(Message::Text(frame.to_string().into()))
        .await
        .expect("send");
}

async fn next_frame(client: &mut Client) -> Value {
    loop {
        let message = tokio::time::timeout(ANSWER_BOUND, client.next())
            .await
            .expect("the relay answered within the bound")
            .expect("the relay kept the connection open")
            .expect("a readable message");
        if let Message::Text(text) = message {
            return serde_json::from_str(text.as_str()).expect("a JSON frame");
        }
    }
}

/// Every frame up to and including the `EOSE` for `sub`.
async fn until_eose(client: &mut Client, sub: &str) -> Vec<Value> {
    let mut frames = Vec::new();
    loop {
        let frame = next_frame(client).await;
        let done = frame[0] == "EOSE" && frame[1] == sub;
        frames.push(frame);
        if done {
            return frames;
        }
    }
}

fn list_event(keys: &Keys, kind: u16, relay: &str) -> Value {
    let event = EventBuilder::new(Kind::from(kind), "")
        .tag(Tag::parse(["relay", relay]).expect("tag"))
        .sign_with_keys(keys)
        .expect("sign");
    serde_json::to_value(&event).expect("event json")
}

async fn control(client: &mut Client, frame: Value) -> Value {
    send(client, &frame).await;
    next_frame(client).await
}

async fn offers(control_socket: &mut Client) -> Value {
    let reply = control(control_socket, json!(["HAVEN_FAULT_OFFERS"])).await;
    assert_eq!(reply[0], "HAVEN_FAULT_OFFERS_ACK");
    reply[1].clone()
}

async fn kept(control_socket: &mut Client) -> Vec<Value> {
    let reply = control(control_socket, json!(["HAVEN_FAULT_KEPT"])).await;
    assert_eq!(reply[0], "HAVEN_FAULT_KEPT_ACK");
    reply[1].as_array().expect("an event list").clone()
}

fn req(sub: &str, kind: u16) -> Value {
    json!(["REQ", sub, {"kinds": [kind]}])
}

#[tokio::test]
async fn store_mode_keeps_serves_and_counts_an_offer() {
    let (_relay, url) = start(Mode::Store).await;
    let keys = Keys::generate();
    let event = list_event(&keys, 10050, "a");
    let mut app = connect(&url).await;
    send(&mut app, &json!(["EVENT", event])).await;
    let ok = next_frame(&mut app).await;
    assert_eq!(ok[0], "OK");
    assert_eq!(ok[1], event["id"]);
    assert_eq!(ok[2], true, "a storing relay accepts a valid event");
    send(&mut app, &req("s", 10050)).await;
    let frames = until_eose(&mut app, "s").await;
    assert_eq!(frames.len(), 2, "the stored event, then EOSE");
    assert_eq!(frames[0][2]["id"], event["id"]);

    let mut test = connect(&url).await;
    assert_eq!(offers(&mut test).await, json!({"10050": 1}));
    let stored = kept(&mut test).await;
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0]["id"], event["id"]);
}

#[tokio::test]
async fn refuse_mode_answers_ok_false_keeps_nothing_and_still_answers_reqs() {
    let (_relay, url) = start(Mode::Refuse).await;
    let event = list_event(&Keys::generate(), 10002, "a");
    let mut app = connect(&url).await;
    send(&mut app, &json!(["EVENT", event])).await;
    let ok = next_frame(&mut app).await;
    assert_eq!(ok, json!(["OK", event["id"], false, REFUSAL]));
    send(&mut app, &req("s", 10002)).await;
    assert_eq!(
        until_eose(&mut app, "s").await,
        vec![json!(["EOSE", "s"])],
        "the relay answers a REQ, holding nothing"
    );

    let mut test = connect(&url).await;
    assert_eq!(offers(&mut test).await, json!({"10002": 1}));
    assert!(kept(&mut test).await.is_empty());
}

#[tokio::test]
async fn drop_mode_never_answers_an_event_and_keeps_nothing() {
    let (_relay, url) = start(Mode::Drop).await;
    let event = list_event(&Keys::generate(), 30443, "a");
    let mut app = connect(&url).await;
    send(&mut app, &json!(["EVENT", event])).await;
    send(&mut app, &req("s", 30443)).await;
    assert_eq!(
        until_eose(&mut app, "s").await,
        vec![json!(["EOSE", "s"])],
        "no OK and no stored copy came before the EOSE of a later REQ"
    );

    let mut test = connect(&url).await;
    assert_eq!(offers(&mut test).await, json!({"30443": 1}));
    assert!(kept(&mut test).await.is_empty());
}

#[tokio::test]
async fn stall_mode_swallows_events_and_reqs() {
    let (_relay, url) = start(Mode::Stall).await;
    let event = list_event(&Keys::generate(), 10050, "a");
    let mut app = connect(&url).await;
    send(&mut app, &json!(["EVENT", event])).await;
    send(&mut app, &req("stalled", 10050)).await;
    // The same socket, switched to store: had the first REQ been handed on, its
    // EOSE would come before the second one's.
    assert_eq!(
        control(&mut app, json!(["HAVEN_FAULT_MODE", "store"])).await,
        json!(["HAVEN_FAULT_MODE_ACK", "store"])
    );
    send(&mut app, &req("after", 10050)).await;
    assert_eq!(
        until_eose(&mut app, "after").await,
        vec![json!(["EOSE", "after"])],
        "nothing answered the stalled EVENT or REQ"
    );
    let mut test = connect(&url).await;
    assert_eq!(offers(&mut test).await, json!({"10050": 1}));
    assert!(kept(&mut test).await.is_empty());
}

#[tokio::test]
async fn blackhole_mode_takes_the_upgrade_request_and_never_answers_it() {
    let (_relay, url) = start(Mode::Blackhole).await;
    let mut tcp = TcpStream::connect(url.trim_start_matches("ws://"))
        .await
        .expect("the TCP connection is accepted");
    tcp.write_all(
        b"GET / HTTP/1.1\r\nHost: relay\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
          Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
    )
    .await
    .expect("write the upgrade request");
    tcp.shutdown().await.expect("half-close");
    let mut answer = Vec::new();
    tokio::time::timeout(ANSWER_BOUND, tcp.read_to_end(&mut answer))
        .await
        .expect("the relay closed once the client did")
        .expect("read");
    assert!(answer.is_empty(), "not one byte of a handshake answer");
}

#[tokio::test]
async fn wipe_clears_the_store_and_the_offers_and_mode_switches_take_effect() {
    let (_relay, url) = start(Mode::Store).await;
    let keys = Keys::generate();
    let mut app = connect(&url).await;
    let first = list_event(&keys, 10050, "a");
    send(&mut app, &json!(["EVENT", first])).await;
    assert_eq!(next_frame(&mut app).await[2], true);

    let mut test = connect(&url).await;
    assert_eq!(
        control(&mut test, json!(["HAVEN_FAULT_WIPE"])).await,
        json!(["HAVEN_FAULT_WIPE_ACK"])
    );
    assert!(kept(&mut test).await.is_empty());
    assert_eq!(offers(&mut test).await, json!({}));

    assert_eq!(
        control(&mut test, json!(["HAVEN_FAULT_MODE", "refuse"])).await,
        json!(["HAVEN_FAULT_MODE_ACK", "refuse"])
    );
    let second = list_event(&keys, 10050, "b");
    send(&mut app, &json!(["EVENT", second])).await;
    assert_eq!(
        next_frame(&mut app).await[2],
        false,
        "refused once switched"
    );
    assert_eq!(
        control(&mut test, json!(["HAVEN_FAULT_MODE", "sometimes"])).await,
        json!(["HAVEN_FAULT_REFUSED", "HAVEN_FAULT_MODE"])
    );
    assert_eq!(
        control(&mut test, json!(["HAVEN_FAULT_NOPE"])).await,
        json!(["HAVEN_FAULT_REFUSED", "HAVEN_FAULT_NOPE"])
    );
}

#[tokio::test]
async fn the_test_sockets_own_events_are_kept_but_never_counted_as_offers() {
    let (_relay, url) = start(Mode::Store).await;
    let keys = Keys::generate();
    let mut test = connect(&url).await;
    assert_eq!(offers(&mut test).await, json!({}));
    let seeded = list_event(&keys, 10002, "stale");
    send(&mut test, &json!(["EVENT", seeded])).await;
    assert_eq!(next_frame(&mut test).await[2], true);

    let mut app = connect(&url).await;
    send(&mut app, &json!(["EVENT", list_event(&keys, 10050, "a")])).await;
    assert_eq!(next_frame(&mut app).await[2], true);

    assert_eq!(
        offers(&mut test).await,
        json!({"10050": 1}),
        "the seed is the test's, the 10050 the app's"
    );
    assert_eq!(kept(&mut test).await.len(), 2);
}
