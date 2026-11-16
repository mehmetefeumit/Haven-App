//! A loopback relay address that records every frame a client sends, in
//! front of a real relay it hands every frame on to.
//!
//! Compiled only with `test-utils`. It exists for the relay-plane proof: a
//! relay's own hooks see a filter only after it clamped the `limit`, an event
//! only after its rate limit, and never a `NEG-OPEN` or a `CLOSE`, while this
//! records what the client sent, byte for byte, before the relay acts on it.
//! A gating front ([`RecordingFront::start_gating`]) also plays a relay that
//! withholds gift wraps from a client that has not authenticated, as strfry's
//! `restrictedReadKinds` does. It builds no client and logs nothing; the
//! frames hold identifiers, so no type here has `Debug` (Security Rule 15).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use futures::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, Notify};
use tokio_tungstenite::tungstenite::Message;

/// One client→relay frame.
#[derive(Clone)]
pub struct RecordedFrame {
    /// The connection it came on, numbered from 0 in the order they opened.
    pub conn: usize,
    /// The frame's text; empty for a binary frame.
    pub text: String,
    /// Whether the client sent it as a binary frame.
    pub binary: bool,
}

/// The kinds strfry withholds from a client that has not authenticated, by
/// default (`relay.auth.restrictedReadKinds = "4, 1059"`).
const RESTRICTED_KINDS: [u64; 2] = [4, 1059];

/// strfry's refusal of a read only an authenticated client may make.
const AUTH_REQUIRED: &str = "auth-required: requested filter requires authentication";

#[derive(Default)]
struct Record {
    frames: Mutex<Vec<RecordedFrame>>,
    refused: Mutex<Vec<RecordedFrame>>,
    grew: Notify,
    connections: AtomicUsize,
    closed: AtomicUsize,
}

impl Record {
    fn push(&self, frame: RecordedFrame) {
        self.frames
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(frame);
        self.grew.notify_waiters();
    }
}

/// The front. It stops when stopped or dropped: no new connection is taken,
/// and every open one is closed.
pub struct RecordingFront {
    url: String,
    record: Arc<Record>,
    stop: Option<oneshot::Sender<()>>,
}

impl RecordingFront {
    /// Starts a front for the relay at `upstream` (`ws://host:port`) on a
    /// loopback port of its own, on a thread of its own, so it outlives any one
    /// test's runtime, and arms the loopback opt-in.
    ///
    /// # Panics
    ///
    /// If the front cannot bind: a test that cannot build its environment has
    /// nothing to assert.
    #[must_use]
    pub fn start(upstream: &str) -> Self {
        Self::start_with(upstream, false)
    }

    /// [`Self::start`] for a front that answers as a relay restricting the
    /// reads of kinds 4 and 1059 — strfry's default — answers a client that
    /// never authenticates (strfry `RelayIngester.cpp`, `ReadRestrictor.h`): a
    /// `REQ` whose every filter names only such kinds, a `COUNT` with a
    /// filter naming one, and a `NEG-OPEN` whose filter names only such kinds
    /// are refused with an `AUTH` challenge and then `CLOSED` — `NEG-ERR` for
    /// the `NEG-OPEN` — and never reach the relay; an event of such a kind the
    /// relay serves for any other `REQ` is withheld. Everything else, every
    /// `EVENT` a client publishes among it, is handed on as by [`Self::start`].
    ///
    /// # Panics
    ///
    /// As [`Self::start`].
    #[must_use]
    pub fn start_gating(upstream: &str) -> Self {
        Self::start_with(upstream, true)
    }

    fn start_with(upstream: &str, gating: bool) -> Self {
        let _ = super::allow_ws_loopback_for_test();
        let record = Arc::new(Record::default());
        let serving = Arc::clone(&record);
        let upstream = upstream.trim_end_matches('/').to_owned();
        let (url_tx, url_rx) = std::sync::mpsc::channel();
        let (stop, stopped) = oneshot::channel::<()>();
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_io()
                .build()
                .expect("recording front runtime")
                .block_on(async move {
                    let listener = TcpListener::bind("127.0.0.1:0")
                        .await
                        .expect("bind a loopback port");
                    let port = listener.local_addr().expect("local address").port();
                    url_tx
                        .send(format!("ws://127.0.0.1:{port}"))
                        .expect("hand the url over");
                    tokio::spawn(accept(listener, upstream, gating, serving));
                    // Resolves when the handle is stopped or dropped; the
                    // runtime and every connection task go with it.
                    let _ = stopped.await;
                });
        });
        Self {
            url: url_rx.recv().expect("recording front url"),
            record,
            stop: Some(stop),
        }
    }

    /// The front's `ws://127.0.0.1:<port>` address.
    #[must_use]
    pub fn url(&self) -> &str {
        &self.url
    }

    /// Every frame recorded so far, in the order the front read them.
    #[must_use]
    pub fn frames(&self) -> Vec<RecordedFrame> {
        self.record
            .frames
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Every frame a gating front refused, in the order it read them; each is
    /// also among [`Self::frames`], and recorded here before it is there.
    #[must_use]
    pub fn refused(&self) -> Vec<RecordedFrame> {
        self.record
            .refused
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// How many connections clients have opened here.
    #[must_use]
    pub fn connections(&self) -> usize {
        self.record.connections.load(Ordering::SeqCst)
    }

    /// How many of those connections have ended: the client closed its socket,
    /// or it went.
    #[must_use]
    pub fn closed(&self) -> usize {
        self.record.closed.load(Ordering::SeqCst)
    }

    /// Resolves once `count` connections have ended, woken by each ending.
    /// Unbounded: the caller bounds it.
    pub async fn wait_closed(&self, count: usize) {
        loop {
            let grew = self.record.grew.notified();
            tokio::pin!(grew);
            grew.as_mut().enable();
            if self.closed() >= count {
                return;
            }
            grew.await;
        }
    }

    /// Resolves once `done` holds over the frames recorded so far, woken by
    /// each new frame. Unbounded: the caller bounds it.
    pub async fn wait_for(&self, done: impl Fn(&[RecordedFrame]) -> bool) {
        loop {
            let grew = self.record.grew.notified();
            tokio::pin!(grew);
            grew.as_mut().enable();
            if done(
                &self
                    .record
                    .frames
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner),
            ) {
                return;
            }
            grew.await;
        }
    }

    /// Stops the front; what it recorded stays readable.
    pub fn stop(&mut self) {
        self.stop.take();
    }
}

async fn accept(listener: TcpListener, upstream: String, gating: bool, record: Arc<Record>) {
    while let Ok((tcp, _)) = listener.accept().await {
        let conn = record.connections.fetch_add(1, Ordering::SeqCst);
        let serving = Arc::clone(&record);
        let upstream = upstream.clone();
        tokio::spawn(async move {
            serve(tcp, upstream, conn, gating, Arc::clone(&serving)).await;
            serving.closed.fetch_add(1, Ordering::SeqCst);
            serving.grew.notify_waiters();
        });
    }
}

async fn serve(tcp: TcpStream, upstream: String, conn: usize, gating: bool, record: Arc<Record>) {
    let Ok(client) = tokio_tungstenite::accept_async(tcp).await else {
        return;
    };
    let Ok(upstream_tcp) = TcpStream::connect(upstream.trim_start_matches("ws://")).await else {
        return;
    };
    let Ok((relay, _)) = tokio_tungstenite::client_async(upstream.as_str(), upstream_tcp).await
    else {
        return;
    };
    let (mut to_client, mut from_client) = client.split();
    let (mut to_relay, from_relay) = relay.split();
    let (answers, answered) = futures::channel::mpsc::unbounded::<Message>();
    let relay_to_client = tokio::spawn(async move {
        // The relay's end ends the client's connection, as it did before the
        // front's own answers joined the stream.
        let relayed = from_relay
            .map(Result::ok)
            .chain(futures::stream::iter([None]));
        let mut outgoing = futures::stream::select(answered.map(Some), relayed);
        while let Some(Some(message)) = outgoing.next().await {
            if gating && withheld(&message) {
                continue;
            }
            if to_client.send(message).await.is_err() {
                break;
            }
        }
        let _ = to_client.close().await;
    });
    while let Some(Ok(message)) = from_client.next().await {
        match &message {
            Message::Text(text) => {
                let frame = RecordedFrame {
                    conn,
                    text: text.as_str().to_owned(),
                    binary: false,
                };
                let refusal = if gating {
                    refusal(text.as_str(), conn)
                } else {
                    None
                };
                if let Some(refusal) = refusal {
                    record
                        .refused
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .push(frame.clone());
                    record.push(frame);
                    if refusal
                        .into_iter()
                        .any(|answer| answers.unbounded_send(answer).is_err())
                    {
                        break;
                    }
                    continue;
                }
                record.push(frame);
            }
            Message::Binary(_) => record.push(RecordedFrame {
                conn,
                text: String::new(),
                binary: true,
            }),
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
        }
        if to_relay.send(message).await.is_err() {
            break;
        }
    }
    let _ = to_relay.close().await;
    relay_to_client.abort();
}

/// What a gating front answers a client frame strfry refuses a client that
/// has not authenticated: an `AUTH` challenge, then the refusal. `None` for
/// every frame it hands on.
fn refusal(text: &str, conn: usize) -> Option<[Message; 2]> {
    let frame: serde_json::Value = serde_json::from_str(text).ok()?;
    let frame = frame.as_array()?;
    let verb = frame.first()?.as_str()?;
    let id = frame.get(1)?.as_str()?;
    let filters = frame.get(2..)?;
    let refused = match verb {
        "REQ" => !filters.is_empty() && filters.iter().all(only_restricted),
        "COUNT" => filters.iter().any(names_restricted),
        "NEG-OPEN" => filters.first().is_some_and(only_restricted),
        _ => false,
    };
    if !refused {
        return None;
    }
    let refusal = if verb == "NEG-OPEN" {
        serde_json::json!(["NEG-ERR", id, AUTH_REQUIRED])
    } else {
        // strfry's `sendClosedError` puts `ERROR: ` before every `CLOSED`
        // reason it sends.
        serde_json::json!(["CLOSED", id, format!("ERROR: {AUTH_REQUIRED}")])
    };
    Some([
        Message::text(serde_json::json!(["AUTH", format!("challenge-{conn}")]).to_string()),
        Message::text(refusal.to_string()),
    ])
}

fn kinds(filter: &serde_json::Value) -> Option<impl Iterator<Item = Option<u64>> + '_> {
    Some(
        filter
            .get("kinds")?
            .as_array()?
            .iter()
            .map(serde_json::Value::as_u64),
    )
}

/// strfry's `isFilterFullyRestricted`: the filter names kinds, every one of
/// them restricted.
fn only_restricted(filter: &serde_json::Value) -> bool {
    kinds(filter).is_some_and(|mut kinds| {
        kinds.all(|kind| kind.is_some_and(|kind| RESTRICTED_KINDS.contains(&kind)))
    })
}

/// strfry's test in `isFilterAllowedToCount`: the filter names a restricted
/// kind.
fn names_restricted(filter: &serde_json::Value) -> bool {
    kinds(filter).is_some_and(|mut kinds| {
        kinds.any(|kind| kind.is_some_and(|kind| RESTRICTED_KINDS.contains(&kind)))
    })
}

/// strfry's `shouldSendToSubscriber` for a client that has not
/// authenticated: no event of a restricted kind reaches it.
fn withheld(message: &Message) -> bool {
    let Message::Text(text) = message else {
        return false;
    };
    serde_json::from_str::<serde_json::Value>(text.as_str()).is_ok_and(|frame| {
        frame.get(0).and_then(serde_json::Value::as_str) == Some("EVENT")
            && frame
                .get(2)
                .and_then(|event| event.get("kind"))
                .and_then(serde_json::Value::as_u64)
                .is_some_and(|kind| RESTRICTED_KINDS.contains(&kind))
    })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use nostr::{EventBuilder, Filter, JsonUtil as _, Keys, Kind};
    use nostr_sdk::ClientOptions;

    use super::*;
    use crate::relay::scripted_relay::ScriptedRelay;
    use crate::relay::verified::verified_client;

    /// The longest a frame may take to reach the front, unscaled.
    const WAIT: Duration = Duration::from_secs(20);

    /// [`WAIT`] scaled by `HAVEN_TEST_WAIT_SCALE` for instrumented runs, as the
    /// e2e tests scale theirs. Absent or unparsable means 1.
    fn budget() -> Duration {
        WAIT * std::env::var("HAVEN_TEST_WAIT_SCALE")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|s| *s >= 1)
            .unwrap_or(1)
    }

    fn json(frame: &RecordedFrame) -> serde_json::Value {
        serde_json::from_str(&frame.text).expect("a recorded text frame is the client's JSON")
    }

    /// What a product client sends — a publish, a subscription and its close —
    /// is recorded exactly, in order, on the one connection it opened; a
    /// second client's frames, a binary one among them, are recorded on a
    /// connection of their own, and every frame still reaches the relay.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn recording_front_records_every_client_frame_in_order_per_connection() {
        let relay = ScriptedRelay::start();
        let front = RecordingFront::start(relay.url());
        let client = verified_client(ClientOptions::default(), None);
        client.add_relay(front.url()).await.expect("add the front");
        client.connect().await;

        let event = EventBuilder::text_note("recorded")
            .sign_with_keys(&Keys::generate())
            .expect("a locally built event signs");
        client
            .send_event_to([front.url()], &event)
            .await
            .expect("the relay acknowledges the event");
        let filter = Filter::new().kind(Kind::TextNote).limit(3);
        let sub = client
            .subscribe_to([front.url()], filter.clone(), None)
            .await
            .expect("the subscription is sent")
            .val;
        client.unsubscribe(&sub).await;
        tokio::time::timeout(budget(), front.wait_for(|frames| frames.len() >= 3))
            .await
            .expect("the close reaches the front");
        client.shutdown().await;
        tokio::time::timeout(budget(), front.wait_closed(1))
            .await
            .expect("the shut-down client's connection ends at the front");

        let frames = front.frames();
        assert!(
            frames.iter().all(|frame| frame.conn == 0 && !frame.binary),
            "one client, one connection, text frames only",
        );
        let texts: Vec<serde_json::Value> = frames.iter().map(json).collect();
        assert_eq!(
            texts,
            vec![
                serde_json::json!([
                    "EVENT",
                    serde_json::from_str::<serde_json::Value>(&event.as_json()).unwrap()
                ]),
                serde_json::json!([
                    "REQ",
                    sub.to_string(),
                    serde_json::to_value(&filter).unwrap()
                ]),
                serde_json::json!(["CLOSE", sub.to_string()]),
            ],
            "the front holds exactly what the client sent, in order",
        );
        assert_eq!(
            relay.published(),
            vec![event],
            "the event was handed on to the relay"
        );

        let tcp = TcpStream::connect(front.url().trim_start_matches("ws://"))
            .await
            .expect("dial the front");
        let (mut raw, _) = tokio_tungstenite::client_async(front.url(), tcp)
            .await
            .expect("a raw client's handshake");
        raw.send(Message::Binary(vec![1, 2, 3].into()))
            .await
            .expect("a binary frame");
        raw.send(Message::text(r#"["CLOSE","raw"]"#))
            .await
            .expect("a text frame");
        tokio::time::timeout(budget(), front.wait_for(|frames| frames.len() >= 5))
            .await
            .expect("the raw client's frames reach the front");
        let raw_frames: Vec<(usize, bool, String)> = front.frames()[3..]
            .iter()
            .map(|frame| (frame.conn, frame.binary, frame.text.clone()))
            .collect();
        assert_eq!(
            raw_frames,
            vec![
                (1, true, String::new()),
                (1, false, r#"["CLOSE","raw"]"#.to_owned()),
            ],
            "the second client's frames are on a connection of their own, the binary one flagged",
        );
        assert_eq!(front.connections(), 2);
        assert_eq!(
            front.closed(),
            1,
            "the raw client's connection is still open"
        );
        raw.close(None).await.expect("the raw client closes");
        tokio::time::timeout(budget(), front.wait_closed(2))
            .await
            .expect("the raw client's close reaches the front");
    }

    /// Sends `frame` on a connection of its own and reads the answers until
    /// one that ends the request.
    async fn ask(front: &RecordingFront, frame: &serde_json::Value) -> Vec<serde_json::Value> {
        let tcp = TcpStream::connect(front.url().trim_start_matches("ws://"))
            .await
            .expect("dial the front");
        let (mut raw, _) = tokio_tungstenite::client_async(front.url(), tcp)
            .await
            .expect("a raw client's handshake");
        raw.send(Message::text(frame.to_string()))
            .await
            .expect("the request is sent");
        let mut answers = Vec::new();
        let read = async {
            while let Some(Ok(Message::Text(text))) = raw.next().await {
                let answer: serde_json::Value =
                    serde_json::from_str(text.as_str()).expect("a relay frame is JSON");
                let last = matches!(answer[0].as_str(), Some("EOSE" | "CLOSED" | "NEG-ERR"));
                answers.push(answer);
                if last {
                    break;
                }
            }
        };
        tokio::time::timeout(budget(), read)
            .await
            .expect("the request is answered to its end");
        answers
    }

    fn kinds_served(answers: &[serde_json::Value]) -> Vec<u64> {
        answers
            .iter()
            .filter(|answer| answer[0] == "EVENT")
            .filter_map(|answer| answer[2]["kind"].as_u64())
            .collect()
    }

    /// A gating front answers as strfry with its default restricted kinds
    /// answers a client that never authenticates: a gift-wrap write is taken;
    /// a `REQ` whose every filter names only restricted kinds, a `COUNT` with
    /// a filter naming one and a `NEG-OPEN` naming only them are refused
    /// with an `AUTH` challenge and strfry's own words, and recorded as
    /// refused; any other `REQ` is served, without the gift wrap.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_gating_front_refuses_gift_wrap_reads_as_strfry_does_and_takes_their_writes() {
        const REFUSED: &str = "auth-required: requested filter requires authentication";

        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("an in-process relay");
        let front = RecordingFront::start_gating(relay.url().await.as_str());
        let keys = Keys::generate();
        let wrap = EventBuilder::new(Kind::GiftWrap, "sealed")
            .tag(nostr::Tag::public_key(Keys::generate().public_key()))
            .sign_with_keys(&keys)
            .expect("a locally built event signs");
        let note = EventBuilder::text_note("open")
            .sign_with_keys(&keys)
            .expect("a locally built event signs");
        let client = verified_client(ClientOptions::default(), None);
        client.add_relay(front.url()).await.expect("add the front");
        client.connect().await;
        for event in [&wrap, &note] {
            let output = client
                .send_event_to([front.url()], event)
                .await
                .expect("the publish runs");
            assert!(
                !output.success.is_empty(),
                "a write of kind {} was not taken",
                event.kind.as_u16(),
            );
        }
        client.shutdown().await;

        let refused = ask(&front, &serde_json::json!(["REQ", "r", {"kinds": [1059]}])).await;
        assert_eq!(refused.len(), 2);
        assert_eq!(refused[0][0], "AUTH");
        assert_eq!(
            refused[1],
            serde_json::json!(["CLOSED", "r", format!("ERROR: {REFUSED}")])
        );
        let counted = ask(
            &front,
            &serde_json::json!(["COUNT", "c", {"kinds": [1, 1059]}]),
        )
        .await;
        assert_eq!(counted[0][0], "AUTH");
        assert_eq!(
            counted[1],
            serde_json::json!(["CLOSED", "c", format!("ERROR: {REFUSED}")])
        );
        let negotiated = ask(
            &front,
            &serde_json::json!(["NEG-OPEN", "n", {"kinds": [1059]}, "6100"]),
        )
        .await;
        assert_eq!(negotiated[0][0], "AUTH");
        assert_eq!(negotiated[1], serde_json::json!(["NEG-ERR", "n", REFUSED]));

        for open in [
            serde_json::json!(["REQ", "o", {"kinds": [1]}]),
            serde_json::json!(["REQ", "m", {"kinds": [1059]}, {"kinds": [1]}]),
            serde_json::json!(["REQ", "a", {}]),
        ] {
            let served = ask(&front, &open).await;
            assert_eq!(
                served.last().map(|answer| answer[0].clone()),
                Some(serde_json::json!("EOSE")),
                "a read that is not wholly of gift wraps was refused: {open}",
            );
            assert_eq!(
                kinds_served(&served),
                [1],
                "a gift wrap reached a client that never authenticated, or the note did not",
            );
        }

        let refused_ids: Vec<(String, String)> = front
            .refused()
            .iter()
            .map(|frame| {
                let frame = json(frame);
                (
                    frame[0].as_str().unwrap_or_default().to_owned(),
                    frame[1].as_str().unwrap_or_default().to_owned(),
                )
            })
            .collect();
        assert_eq!(
            refused_ids,
            [("REQ", "r"), ("COUNT", "c"), ("NEG-OPEN", "n")]
                .map(|(verb, id)| (verb.to_owned(), id.to_owned())),
        );
    }
}
