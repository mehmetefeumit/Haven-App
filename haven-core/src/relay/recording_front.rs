//! A loopback relay address that records every frame a client sends, in
//! front of a real relay it hands every frame on to.
//!
//! Compiled only with `test-utils`. It exists for the relay-plane proof: a
//! relay's own hooks see a filter only after it clamped the `limit`, an event
//! only after its rate limit, and never a `NEG-OPEN` or a `CLOSE`, while this
//! records what the client sent, byte for byte, before the relay acts on it.
//! It builds no client and logs nothing; the frames hold identifiers, so no
//! type here has `Debug` (Security Rule 15).

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

#[derive(Default)]
struct Record {
    frames: Mutex<Vec<RecordedFrame>>,
    grew: Notify,
    connections: AtomicUsize,
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
                    tokio::spawn(accept(listener, upstream, serving));
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

    /// How many connections clients have opened here.
    #[must_use]
    pub fn connections(&self) -> usize {
        self.record.connections.load(Ordering::SeqCst)
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

async fn accept(listener: TcpListener, upstream: String, record: Arc<Record>) {
    while let Ok((tcp, _)) = listener.accept().await {
        let conn = record.connections.fetch_add(1, Ordering::SeqCst);
        tokio::spawn(serve(tcp, upstream.clone(), conn, Arc::clone(&record)));
    }
}

async fn serve(tcp: TcpStream, upstream: String, conn: usize, record: Arc<Record>) {
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
    let (mut to_relay, mut from_relay) = relay.split();
    let relay_to_client = tokio::spawn(async move {
        while let Some(Ok(message)) = from_relay.next().await {
            if to_client.send(message).await.is_err() {
                break;
            }
        }
        let _ = to_client.close().await;
    });
    while let Some(Ok(message)) = from_client.next().await {
        match &message {
            Message::Text(text) => record.push(RecordedFrame {
                conn,
                text: text.as_str().to_owned(),
                binary: false,
            }),
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
    }
}
