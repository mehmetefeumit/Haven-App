//! A loopback relay that misbehaves on purpose, for the relay-management lane.
//!
//! Each instance fronts an in-memory [`LocalRelay`] (full NIP-01: filters,
//! replaceable and addressable events, `EOSE`) and, per its [`Mode`], hands a
//! client's frames on, answers them itself, or swallows them. That is what lets
//! the device test see every state the Relays page can show against a real
//! socket: a relay that refuses (`OK false`), one that never answers `OK`, one
//! that never ends a `REQ`, one that never completes the WebSocket handshake.
//!
//! The backing relay is reached over an in-process duplex pipe
//! ([`LocalRelay::take_connection`]), so it holds no port of its own.
//!
//! # Control verbs
//!
//! A frame whose verb starts with `HAVEN_FAULT_` is answered here and never
//! reaches the backing relay. A connection that sends one is the test's own
//! socket: its events are never counted as offers, whatever the mode.
//!
//! | Frame | Reply |
//! |---|---|
//! | `["HAVEN_FAULT_MODE", "<mode>"]` | `["HAVEN_FAULT_MODE_ACK", "<mode>"]` |
//! | `["HAVEN_FAULT_WIPE"]` | `["HAVEN_FAULT_WIPE_ACK"]` (store and offers cleared) |
//! | `["HAVEN_FAULT_OFFERS"]` | `["HAVEN_FAULT_OFFERS_ACK", {"<kind>": <events offered>}]` |
//! | `["HAVEN_FAULT_KEPT"]` | `["HAVEN_FAULT_KEPT_ACK", [<every stored event>]]` |
//! | anything else | `["HAVEN_FAULT_REFUSED", "<verb>"]` |
//!
//! # It logs nothing
//!
//! Frames carry pubkeys, event ids and filters (Security Rule 15), so nothing
//! here prints, and no type here has `Debug`. The binary's fixed startup block
//! is the whole of its log.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use futures_util::{SinkExt, StreamExt};
use nostr_relay_builder::prelude::{
    Filter, LocalRelay, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase, RelayBuilder,
};
use serde_json::{json, Value};
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::protocol::Role;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

/// Environment variable naming the listen port (required by the binary).
pub const ENV_FAULT_PORT: &str = "HAVEN_FAULT_PORT";

/// Environment variable naming the starting [`Mode`] (required by the binary).
pub const ENV_FAULT_MODE: &str = "HAVEN_FAULT_MODE";

/// Prefix of every control verb.
pub const CONTROL_PREFIX: &str = "HAVEN_FAULT_";

/// The text of the refusal [`Mode::Refuse`] answers every event with: a NIP-01
/// machine-readable prefix, so the client classifies it as a relay's refusal.
pub const REFUSAL: &str = "blocked: e2e fixture";

/// How the relay treats a client's frames.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Hands every frame on: a healthy relay.
    Store,
    /// Answers every event `OK false` and keeps none; hands everything else on.
    Refuse,
    /// Swallows every event (no `OK`, nothing kept); hands everything else on.
    Drop,
    /// Swallows every frame, so no `REQ` ever ends.
    Stall,
    /// Accepts the TCP connection and never completes the WebSocket handshake.
    Blackhole,
}

impl Mode {
    const ALL: [Self; 5] = [
        Self::Store,
        Self::Refuse,
        Self::Drop,
        Self::Stall,
        Self::Blackhole,
    ];

    /// The mode's name, as `HAVEN_FAULT_MODE` and the control verb spell it.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Store => "store",
            Self::Refuse => "refuse",
            Self::Drop => "drop",
            Self::Stall => "stall",
            Self::Blackhole => "blackhole",
        }
    }

    /// The mode named `name`, if any.
    #[must_use]
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|mode| mode.name() == name)
    }

    const fn code(self) -> u8 {
        self as u8
    }

    fn from_code(code: u8) -> Self {
        Self::ALL[usize::from(code)]
    }
}

struct Shared {
    mode: AtomicU8,
    offers: Mutex<BTreeMap<u64, u64>>,
    database: Arc<MemoryDatabase>,
    relay: LocalRelay,
}

impl Shared {
    fn mode(&self) -> Mode {
        Mode::from_code(self.mode.load(Ordering::SeqCst))
    }

    fn offers(&self) -> std::sync::MutexGuard<'_, BTreeMap<u64, u64>> {
        self.offers.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// What the front does with one client frame.
enum Action {
    Forward,
    Reply(String),
    Swallow,
}

/// A running fault relay. Dropping it stops taking connections.
pub struct FaultRelay {
    accept: JoinHandle<()>,
}

impl FaultRelay {
    /// Serves `listener` in `mode`, on the current runtime.
    #[must_use]
    pub fn start(listener: TcpListener, mode: Mode) -> Self {
        let database = Arc::new(MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        }));
        let relay = LocalRelay::new(RelayBuilder::default().database(Arc::clone(&database)));
        let shared = Arc::new(Shared {
            mode: AtomicU8::new(mode.code()),
            offers: Mutex::new(BTreeMap::new()),
            database,
            relay,
        });
        Self {
            accept: tokio::spawn(accept(listener, shared)),
        }
    }
}

impl Drop for FaultRelay {
    fn drop(&mut self) {
        self.accept.abort();
    }
}

async fn accept(listener: TcpListener, shared: Arc<Shared>) {
    while let Ok((tcp, peer)) = listener.accept().await {
        tokio::spawn(serve(tcp, peer, Arc::clone(&shared)));
    }
}

async fn serve(mut tcp: TcpStream, peer: SocketAddr, shared: Arc<Shared>) {
    if shared.mode() == Mode::Blackhole {
        // Read and discard until the client gives up, so it sees a socket that
        // took its upgrade request and never answered.
        let mut sink = [0_u8; 1024];
        while matches!(tcp.read(&mut sink).await, Ok(n) if n > 0) {}
        return;
    }
    let Ok(client) = tokio_tungstenite::accept_async(tcp).await else {
        return;
    };
    let (front_end, relay_end) = tokio::io::duplex(1 << 20);
    let relay = shared.relay.clone();
    let backing = tokio::spawn(async move {
        let _ = relay.take_connection(relay_end, peer).await;
    });
    let upstream = WebSocketStream::from_raw_socket(front_end, Role::Client, None).await;
    let (mut to_client, mut from_client) = client.split();
    let (mut to_relay, mut from_relay) = upstream.split();
    // One writer, so the backing relay's answers and this front's own replies
    // never interleave inside a frame.
    let (out, mut outgoing) = mpsc::unbounded_channel::<Message>();
    let writer = tokio::spawn(async move {
        while let Some(message) = outgoing.recv().await {
            if to_client.send(message).await.is_err() {
                break;
            }
        }
        let _ = to_client.close().await;
    });
    let relayed = out.clone();
    let pump = tokio::spawn(async move {
        while let Some(Ok(message)) = from_relay.next().await {
            if matches!(message, Message::Text(_) | Message::Binary(_))
                && relayed.send(message).is_err()
            {
                break;
            }
        }
    });
    let mut harness = false;
    while let Some(Ok(message)) = from_client.next().await {
        let action = match &message {
            Message::Text(text) => act(&shared, text.as_str(), &mut harness).await,
            Message::Binary(_) => match shared.mode() {
                Mode::Stall | Mode::Blackhole => Action::Swallow,
                Mode::Store | Mode::Refuse | Mode::Drop => Action::Forward,
            },
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => Action::Swallow,
        };
        match action {
            Action::Forward => {
                if to_relay.send(message).await.is_err() {
                    break;
                }
            }
            Action::Reply(frame) => {
                if out.send(Message::text(frame)).is_err() {
                    break;
                }
            }
            Action::Swallow => {}
        }
    }
    let _ = to_relay.close().await;
    pump.abort();
    backing.abort();
    drop(out);
    let _ = writer.await;
}

async fn act(shared: &Shared, text: &str, harness: &mut bool) -> Action {
    let frame: Option<Vec<Value>> = serde_json::from_str(text).ok();
    let verb = frame
        .as_ref()
        .and_then(|frame| frame.first())
        .and_then(Value::as_str);
    if let Some(verb) = verb.filter(|verb| verb.starts_with(CONTROL_PREFIX)) {
        *harness = true;
        let argument = frame.as_ref().and_then(|frame| frame.get(1));
        return Action::Reply(control(shared, verb, argument).await.to_string());
    }
    let mode = shared.mode();
    if verb != Some("EVENT") {
        return match mode {
            Mode::Stall | Mode::Blackhole => Action::Swallow,
            Mode::Store | Mode::Refuse | Mode::Drop => Action::Forward,
        };
    }
    let event = frame.as_ref().and_then(|frame| frame.get(1));
    if !*harness {
        if let Some(kind) = event
            .and_then(|event| event.get("kind"))
            .and_then(Value::as_u64)
        {
            *shared.offers().entry(kind).or_insert(0) += 1;
        }
    }
    match mode {
        Mode::Store => Action::Forward,
        Mode::Refuse => {
            let id = event
                .and_then(|event| event.get("id"))
                .cloned()
                .unwrap_or(Value::Null);
            Action::Reply(json!(["OK", id, false, REFUSAL]).to_string())
        }
        Mode::Drop | Mode::Stall | Mode::Blackhole => Action::Swallow,
    }
}

async fn control(shared: &Shared, verb: &str, argument: Option<&Value>) -> Value {
    match verb {
        "HAVEN_FAULT_MODE" => argument
            .and_then(Value::as_str)
            .and_then(Mode::parse)
            .map_or_else(
                || json!(["HAVEN_FAULT_REFUSED", verb]),
                |mode| {
                    shared.mode.store(mode.code(), Ordering::SeqCst);
                    json!(["HAVEN_FAULT_MODE_ACK", mode.name()])
                },
            ),
        "HAVEN_FAULT_WIPE" => {
            if shared.database.wipe().await.is_err() {
                return json!(["HAVEN_FAULT_REFUSED", verb]);
            }
            shared.offers().clear();
            json!(["HAVEN_FAULT_WIPE_ACK"])
        }
        "HAVEN_FAULT_OFFERS" => {
            let offers: serde_json::Map<String, Value> = shared
                .offers()
                .iter()
                .map(|(kind, count)| (kind.to_string(), json!(count)))
                .collect();
            json!(["HAVEN_FAULT_OFFERS_ACK", offers])
        }
        "HAVEN_FAULT_KEPT" => shared.database.query(Filter::new()).await.map_or_else(
            |_| json!(["HAVEN_FAULT_REFUSED", verb]),
            |events| json!(["HAVEN_FAULT_KEPT_ACK", events.to_vec()]),
        ),
        _ => json!(["HAVEN_FAULT_REFUSED", verb]),
    }
}
