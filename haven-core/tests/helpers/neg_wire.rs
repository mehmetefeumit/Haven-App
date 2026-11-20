//! A WebSocket endpoint in front of an in-process relay that records every
//! text frame each way, and can stand in for the relay's side of a NIP-77
//! session.
//!
//! `nostr-relay-builder` has no switch to turn NIP-77 off, and serves every
//! session it is asked; the shapes a real relay takes that it does not — a
//! relay that refuses NIP-77 outright, one that refuses one session, one that
//! never answers the opening message — are staged here, frame-accurately, on
//! the one socket the client opened. Everything else passes through verbatim.
//! Loopback only; one task pair per connection.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use futures::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

/// Which way a frame went.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Dir {
    /// From the client to the relay.
    ToRelay,
    /// From the relay (or this endpoint standing in for it) to the client.
    ToClient,
}

/// One recorded text frame, with the connection it crossed.
#[derive(Clone, Debug)]
pub struct Frame {
    pub conn: usize,
    pub dir: Dir,
    pub text: String,
}

impl Frame {
    /// The frame as a JSON array, if it is one.
    pub fn json(&self) -> Option<Vec<serde_json::Value>> {
        serde_json::from_str(&self.text).ok()
    }

    /// The frame's verb: `REQ`, `NEG-OPEN`, `EVENT`, ...
    pub fn verb(&self) -> Option<String> {
        self.json()?.first()?.as_str().map(str::to_string)
    }
}

/// What the endpoint does with a client's `NEG-OPEN`.
#[derive(Clone)]
pub enum NegPolicy {
    /// Passes it to the relay, which runs the session.
    Forward,
    /// Answers `["NOTICE", text]` and forwards nothing: a relay that does not
    /// speak NIP-77 (strfry's `"ERROR: bad msg: unknown cmd"` shape).
    Notice(String),
    /// Answers `["NEG-ERR", <id>, text]` and forwards nothing.
    NegErr(String),
    /// Forwards nothing and answers nothing.
    Silent,
    /// Forwards nothing and answers as a relay holding exactly these ids
    /// would: one `NEG-MSG` whose single range lists them all, which ends the
    /// session for a client with an empty set.
    Answer(Vec<[u8; 32]>),
}

/// A negentropy message holding one range over everything, listing `ids`:
/// version 1, the infinity bound (`00 00`), mode `IdList`, the count, the ids
/// (negentropy 0.5.0 `lib.rs`; counts are base-128, most significant group
/// first, every group but the last flagged).
pub fn id_list_message(ids: &[[u8; 32]]) -> String {
    let mut out = vec![0x61, 0x00, 0x00, 0x02];
    let mut count = ids.len();
    let mut groups = vec![u8::try_from(count & 0x7f).unwrap()];
    count >>= 7;
    while count > 0 {
        groups.push(u8::try_from(count & 0x7f).unwrap() | 0x80);
        count >>= 7;
    }
    groups.reverse();
    out.extend(groups);
    for id in ids {
        out.extend_from_slice(id);
    }
    hex::encode(out)
}

/// What the endpoint does to the relay's `EVENT` frames.
#[derive(Default)]
struct Edits {
    /// Ids whose `EVENT` is sent with its content rewritten, its id and
    /// signature kept: a forged copy under a genuine id.
    forged: Vec<String>,
    /// Whether the relay's `EOSE` for a by-id REQ is withheld: the answer
    /// never finishes.
    unfinished_by_id: bool,
}

/// The endpoint. It stops serving new connections when dropped.
pub struct NegWire {
    pub url: String,
    frames: Arc<Mutex<Vec<Frame>>>,
    policy: Arc<Mutex<NegPolicy>>,
    edits: Arc<Mutex<Edits>>,
    closed: Arc<Mutex<Vec<usize>>>,
    opened: Arc<AtomicUsize>,
    /// Open (`true`) lets a new connection's handshake through; closed holds
    /// it until reopened.
    gate: tokio::sync::watch::Sender<bool>,
    held: Arc<AtomicUsize>,
    accept: tokio::task::JoinHandle<()>,
}

impl Drop for NegWire {
    fn drop(&mut self) {
        self.accept.abort();
    }
}

impl NegWire {
    /// Stands in front of the relay at `relay_url` (`ws://host:port`).
    ///
    /// # Panics
    ///
    /// If a loopback port cannot be bound: a test that cannot build its
    /// environment has nothing to assert.
    pub async fn in_front_of(relay_url: &str, policy: NegPolicy) -> Self {
        let _ = haven_core::relay::allow_ws_loopback_for_test();
        let target = relay_url.to_string();
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let url = format!("ws://{}", listener.local_addr().expect("local addr"));
        let frames = Arc::new(Mutex::new(Vec::new()));
        let policy = Arc::new(Mutex::new(policy));
        let edits = Arc::new(Mutex::new(Edits::default()));
        let closed = Arc::new(Mutex::new(Vec::new()));
        let conns = Arc::new(AtomicUsize::new(0));
        let opened = Arc::clone(&conns);
        let (gate, gated) = tokio::sync::watch::channel(true);
        let held = Arc::new(AtomicUsize::new(0));
        let waiting = Arc::clone(&held);
        let accept = {
            let (frames, policy, closed, edits) = (
                Arc::clone(&frames),
                Arc::clone(&policy),
                Arc::clone(&closed),
                Arc::clone(&edits),
            );
            tokio::spawn(async move {
                while let Ok((tcp, _)) = listener.accept().await {
                    let conn = conns.fetch_add(1, Ordering::SeqCst);
                    let (mut gated, waiting) = (gated.clone(), Arc::clone(&waiting));
                    let serving = serve(
                        tcp,
                        target.clone(),
                        conn,
                        Arc::clone(&frames),
                        Arc::clone(&policy),
                        Arc::clone(&closed),
                        Arc::clone(&edits),
                    );
                    tokio::spawn(async move {
                        if !*gated.borrow() {
                            waiting.fetch_add(1, Ordering::SeqCst);
                            let _ = gated.wait_for(|open| *open).await;
                            waiting.fetch_sub(1, Ordering::SeqCst);
                        }
                        serving.await;
                    });
                }
            })
        };
        Self {
            url,
            frames,
            policy,
            edits,
            closed,
            opened,
            gate,
            held,
            accept,
        }
    }

    /// Every frame recorded so far, in the order they crossed.
    pub fn frames(&self) -> Vec<Frame> {
        self.frames
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// The frames of `verb` that went `dir`.
    pub fn frames_of(&self, dir: Dir, verb: &str) -> Vec<Frame> {
        self.frames()
            .into_iter()
            .filter(|frame| frame.dir == dir && frame.verb().as_deref() == Some(verb))
            .collect()
    }

    /// Sends every `EVENT` of `ids` from here on as a forged copy: content
    /// rewritten, id and signature kept.
    pub fn forge(&self, ids: &[String]) {
        self.edits
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .forged = ids.to_vec();
    }

    /// Changes what the endpoint does with the next `NEG-OPEN`.
    pub fn set_policy(&self, policy: NegPolicy) {
        *self.policy.lock().unwrap_or_else(PoisonError::into_inner) = policy;
    }

    /// Holds every connection accepted from here on before its handshake,
    /// as a relay slow to answer one does; [`Self::release_connections`]
    /// serves each from there.
    pub fn hold_new_connections(&self) {
        self.gate.send_replace(false);
    }

    /// Ends [`Self::hold_new_connections`]: each held socket is served.
    pub fn release_connections(&self) {
        self.gate.send_replace(true);
    }

    /// How many connections are held before their handshake now.
    pub fn held(&self) -> usize {
        self.held.load(Ordering::SeqCst)
    }

    /// How many client sockets have been opened here.
    pub fn connections(&self) -> usize {
        self.opened.load(Ordering::SeqCst)
    }

    /// Withholds the relay's `EOSE` for every by-id REQ from here on.
    pub fn leave_by_id_answers_unfinished(&self) {
        self.edits
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .unfinished_by_id = true;
    }

    /// The connections whose client socket has closed.
    pub fn closed_conns(&self) -> Vec<usize> {
        self.closed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

/// The forged text of one relay frame, when [`Edits`] forge its event.
fn forged(edits: &Mutex<Edits>, text: &str) -> Option<String> {
    let mut frame = serde_json::from_str::<Vec<serde_json::Value>>(text).ok()?;
    if frame.first().and_then(|verb| verb.as_str()) != Some("EVENT") || frame.len() < 3 {
        return None;
    }
    let id = frame[2]["id"].as_str().unwrap_or_default().to_string();
    if !edits
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .forged
        .contains(&id)
    {
        return None;
    }
    frame[2]["content"] = serde_json::Value::String("Zm9yZ2Vk".into());
    Some(serde_json::Value::Array(frame).to_string())
}

/// Remembers the subscription a by-id REQ opened.
fn note_by_id_ask(by_id_subs: &Mutex<Vec<serde_json::Value>>, frame: &[serde_json::Value]) {
    if frame.first().and_then(|verb| verb.as_str()) == Some("REQ")
        && frame.get(2).and_then(|filter| filter.get("ids")).is_some()
    {
        by_id_subs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(frame[1].clone());
    }
}

/// What this endpoint does with one client frame in the relay's place.
enum StandIn {
    /// Passes it on.
    PassOn,
    /// Swallows it.
    Swallow,
    /// Answers with this text and passes nothing on.
    Answer(String),
}

fn stand_in_for_the_relay(policy: &NegPolicy, frame: &[serde_json::Value]) -> StandIn {
    if frame.first().and_then(|verb| verb.as_str()) != Some("NEG-OPEN") {
        return StandIn::PassOn;
    }
    let sub = frame.get(1).cloned().unwrap_or_default();
    match policy {
        NegPolicy::Forward => StandIn::PassOn,
        NegPolicy::Notice(text) => StandIn::Answer(serde_json::json!(["NOTICE", text]).to_string()),
        NegPolicy::NegErr(text) => {
            StandIn::Answer(serde_json::json!(["NEG-ERR", sub, text]).to_string())
        }
        NegPolicy::Silent => StandIn::Swallow,
        NegPolicy::Answer(ids) => {
            StandIn::Answer(serde_json::json!(["NEG-MSG", sub, id_list_message(ids)]).to_string())
        }
    }
}

/// Whether this relay frame is an `EOSE` for a by-id REQ that [`Edits`]
/// leave unfinished.
fn withheld_eose(
    edits: &Mutex<Edits>,
    by_id_subs: &Mutex<Vec<serde_json::Value>>,
    text: &str,
) -> bool {
    if !edits
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .unfinished_by_id
    {
        return false;
    }
    let Ok(frame) = serde_json::from_str::<Vec<serde_json::Value>>(text) else {
        return false;
    };
    frame.first().and_then(|verb| verb.as_str()) == Some("EOSE")
        && frame.get(1).is_some_and(|sub| {
            by_id_subs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains(sub)
        })
}

fn record(frames: &Mutex<Vec<Frame>>, conn: usize, dir: Dir, text: &str) {
    frames
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(Frame {
            conn,
            dir,
            text: text.to_string(),
        });
}

async fn serve(
    tcp: TcpStream,
    target: String,
    conn: usize,
    frames: Arc<Mutex<Vec<Frame>>>,
    policy: Arc<Mutex<NegPolicy>>,
    closed: Arc<Mutex<Vec<usize>>>,
    edits: Arc<Mutex<Edits>>,
) {
    let Ok(client) = tokio_tungstenite::accept_async(tcp).await else {
        return;
    };
    let address = target.trim_start_matches("ws://").trim_end_matches('/');
    let Ok(upstream_tcp) = TcpStream::connect(address).await else {
        return;
    };
    let Ok((upstream, _)) = tokio_tungstenite::client_async(target.as_str(), upstream_tcp).await
    else {
        return;
    };
    let (mut to_client, mut from_client) = client.split();
    let (mut to_relay, mut from_relay) = upstream.split();
    let (reply_tx, mut reply_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let by_id_subs: Arc<Mutex<Vec<serde_json::Value>>> = Arc::new(Mutex::new(Vec::new()));
    let unanswered = Arc::clone(&by_id_subs);

    let relay_frames = Arc::clone(&frames);
    let to_client_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                from = from_relay.next() => {
                    let Some(Ok(mut message)) = from else { break };
                    if let Message::Text(text) = &message {
                        if withheld_eose(&edits, &unanswered, text.as_str()) {
                            continue;
                        }
                        if let Some(forged) = forged(&edits, text.as_str()) {
                            message = Message::text(forged);
                        }
                    }
                    if let Message::Text(text) = &message {
                        record(&relay_frames, conn, Dir::ToClient, text.as_str());
                    }
                    if to_client.send(message).await.is_err() {
                        break;
                    }
                }
                reply = reply_rx.recv() => {
                    let Some(text) = reply else { break };
                    record(&relay_frames, conn, Dir::ToClient, &text);
                    if to_client.send(Message::text(text)).await.is_err() {
                        break;
                    }
                }
            }
        }
        let _ = to_client.close().await;
    });

    while let Some(Ok(message)) = from_client.next().await {
        if let Message::Text(text) = &message {
            record(&frames, conn, Dir::ToRelay, text.as_str());
            if let Ok(frame) = serde_json::from_str::<Vec<serde_json::Value>>(text.as_str()) {
                note_by_id_ask(&by_id_subs, &frame);
                let policy = policy
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                match stand_in_for_the_relay(&policy, &frame) {
                    StandIn::PassOn => {}
                    StandIn::Swallow => continue,
                    StandIn::Answer(answer) => {
                        let _ = reply_tx.send(answer);
                        continue;
                    }
                }
            }
        }
        if matches!(message, Message::Close(_)) {
            break;
        }
        if to_relay.send(message).await.is_err() {
            break;
        }
    }
    closed
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(conn);
    let _ = to_relay.close().await;
    drop(reply_tx);
    to_client_task.abort();
}
