//! A relay that answers every `REQ` with the frames a test scripted for it,
//! and every published event with the verdict a test scripted for it.
//!
//! Compiled only with `test-utils`. It exists for the forged-event tests: a
//! NIP-01 relay, and `nostr-relay-builder`'s, will neither serve two events
//! under one id nor send an `EVENT` under a subscription the client never
//! opened, and a relay that lies about an event needs both. The fanout
//! transport's tests need what a real relay also will not do on request: keep
//! an event and withhold its `OK`, or hang up on one. Loopback only.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use futures::{SinkExt, StreamExt};
use nostr::{event::Event, filter::Filter};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;

/// One frame of a scripted answer.
pub enum Frame {
    /// `EVENT` under the subscription the `REQ` opened.
    Event(Event),
    /// `EVENT` under a subscription id the client never opened: the client's
    /// reader still parses it, and no consumer is waiting for it.
    Unasked(Event),
    /// `EVENT` under the subscription the `REQ` opened, with the event object
    /// as this JSON text, byte for byte: a relay may spell a genuine event
    /// with its keys in another order, extra fields or other escapes.
    Raw(String),
    /// `EOSE` for the subscription the `REQ` opened.
    Eose,
    /// `CLOSED` for the subscription the `REQ` opened, with this text: the
    /// relay ends it without saying it has sent everything.
    Closed(String),
    /// Nothing, until the switch reads `true`: the frames after it wait,
    /// and so does this socket's next client message.
    Hold(tokio::sync::watch::Receiver<bool>),
}

/// One thing the relay does on its socket: send a frame, wait for a
/// [`Frame::Hold`] or [`Verdict::HoldThen`] to open, or hang up.
enum Reply {
    Text(String),
    Hold(tokio::sync::watch::Receiver<bool>),
    HangUp,
}

/// What the relay does with one published event.
pub enum Verdict {
    /// Keeps it and answers `OK true`.
    Keep,
    /// Keeps it and answers `OK true` with this text: `duplicate: …` is how a
    /// relay acknowledges an event it already held.
    KeepSaying(String),
    /// Answers `OK false` with this text, and does not keep it.
    Refuse(String),
    /// Keeps it and answers nothing: a stored event whose `OK` never arrives.
    KeepSilently,
    /// Closes the socket without keeping it or answering.
    HangUp,
    /// Sends these frames, as wire text, and does not keep it.
    Frames(Vec<String>),
    /// Does what the inner verdict does to the store at once, and sends what
    /// it sends — or hangs up — only once the switch reads `true`; the
    /// socket's next client message waits too. A relay whose `OK` a test
    /// releases.
    HoldThen(tokio::sync::watch::Receiver<bool>, Box<Self>),
}

type Asked = Box<dyn Fn(&Filter) -> bool + Send + Sync>;
type Refused = Box<dyn Fn(&Event) -> bool + Send + Sync>;
type Judged = Box<dyn Fn(&Event) -> Verdict + Send + Sync>;

#[derive(Default)]
struct Script {
    answers: Mutex<Vec<(Asked, Vec<Frame>)>>,
    refusals: Mutex<Vec<Refused>>,
    verdict: Mutex<Option<Judged>>,
    published: Mutex<Vec<Event>>,
    serve_kept: std::sync::atomic::AtomicBool,
    offers: AtomicUsize,
    connections: AtomicUsize,
}

/// The relay. It stops when dropped.
pub struct ScriptedRelay {
    url: String,
    script: Arc<Script>,
    _stop: oneshot::Sender<()>,
}

impl ScriptedRelay {
    /// Starts the relay on a loopback port of its own, on a thread of its own,
    /// so it outlives any one test's runtime, and arms the loopback opt-in.
    ///
    /// # Panics
    ///
    /// If the relay cannot bind: a test that cannot build its environment has
    /// nothing to assert.
    #[must_use]
    pub fn start() -> Self {
        let _ = super::allow_ws_loopback_for_test();
        let script = Arc::new(Script::default());
        let serving = Arc::clone(&script);
        let (url_tx, url_rx) = std::sync::mpsc::channel();
        let (stop, stopped) = oneshot::channel::<()>();
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_io()
                .build()
                .expect("scripted relay runtime")
                .block_on(async move {
                    let listener = TcpListener::bind("127.0.0.1:0")
                        .await
                        .expect("bind a loopback port");
                    let port = listener.local_addr().expect("local address").port();
                    url_tx
                        .send(format!("ws://127.0.0.1:{port}"))
                        .expect("hand the url over");
                    tokio::spawn(accept(listener, serving));
                    // Resolves when the handle is dropped; the runtime and
                    // every connection task go with it.
                    let _ = stopped.await;
                });
        });
        Self {
            url: url_rx.recv().expect("scripted relay url"),
            script,
            _stop: stop,
        }
    }

    /// The relay's `ws://127.0.0.1:<port>` address.
    #[must_use]
    pub fn url(&self) -> &str {
        &self.url
    }

    /// Answers every `REQ` carrying a filter `asked` accepts with `frames`, in
    /// order, on the one socket. The newest matching answer wins; a `REQ` no
    /// answer matches gets a bare `EOSE`, as from a relay that holds nothing.
    pub fn answer(
        &self,
        asked: impl Fn(&Filter) -> bool + Send + Sync + 'static,
        frames: Vec<Frame>,
    ) {
        self.script
            .answers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((Box::new(asked), frames));
    }

    /// Answers `OK false` to every published event `refused` accepts, and
    /// does not keep it: a relay that will not take a write.
    pub fn refuse(&self, refused: impl Fn(&Event) -> bool + Send + Sync + 'static) {
        self.script
            .refusals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(Box::new(refused));
    }

    /// Decides every published event from here on with `verdict`, in place of
    /// [`refuse`](Self::refuse) and the default `OK true`.
    pub fn on_publish(&self, verdict: impl Fn(&Event) -> Verdict + Send + Sync + 'static) {
        *self
            .script
            .verdict
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(Box::new(verdict));
    }

    /// Answers every `REQ` no scripted answer matches from what the relay
    /// kept, as a NIP-01 relay would: each kept event a filter matches, only
    /// the newest of a replaceable or addressable coordinate, newest first,
    /// each filter's `limit` honoured, then `EOSE`.
    pub fn serve_kept(&self) {
        self.script.serve_kept.store(true, Ordering::SeqCst);
    }

    /// Every event a client has published here and the relay took, in arrival
    /// order. Each was answered `OK true`, or kept in silence
    /// ([`Verdict::KeepSilently`]).
    #[must_use]
    pub fn published(&self) -> Vec<Event> {
        self.script
            .published
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// How many `EVENT` frames clients have sent here, whatever became of them.
    #[must_use]
    pub fn offers(&self) -> usize {
        self.script.offers.load(Ordering::SeqCst)
    }

    /// How many sockets clients have opened here.
    #[must_use]
    pub fn connections(&self) -> usize {
        self.script.connections.load(Ordering::SeqCst)
    }
}

async fn accept(listener: TcpListener, script: Arc<Script>) {
    while let Ok((tcp, _)) = listener.accept().await {
        tokio::spawn(serve(tcp, Arc::clone(&script)));
    }
}

async fn serve(tcp: TcpStream, script: Arc<Script>) {
    let Ok(mut socket) = tokio_tungstenite::accept_async(tcp).await else {
        return;
    };
    script.connections.fetch_add(1, Ordering::SeqCst);
    while let Some(Ok(frame)) = socket.next().await {
        let Message::Text(text) = frame else { continue };
        let message: Vec<serde_json::Value> =
            serde_json::from_str(&text).expect("a client message is a JSON array");
        // `None` is the relay hanging up: dropping the socket closes it.
        let Some(replies) = script.replies(&message) else {
            return;
        };
        for reply in replies {
            match reply {
                Reply::Text(text) => {
                    if socket.send(Message::text(text)).await.is_err() {
                        return;
                    }
                }
                Reply::Hold(mut open) => {
                    let _ = open.wait_for(|open| *open).await;
                }
                Reply::HangUp => return,
            }
        }
    }
}

impl Script {
    /// What becomes of one published event.
    fn judge(&self, event: &Event) -> Verdict {
        if let Some(verdict) = self
            .verdict
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            return verdict(event);
        }
        let refused = self
            .refusals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|refused| refused(event));
        if refused {
            Verdict::Refuse("blocked: refused".to_string())
        } else {
            Verdict::Keep
        }
    }

    /// What this relay says to one client message; `None` when it hangs up
    /// instead.
    fn replies(&self, message: &[serde_json::Value]) -> Option<Vec<Reply>> {
        Some(match message {
            [verb, event] if verb == "EVENT" => {
                let event: Event =
                    serde_json::from_value(event.clone()).expect("a client publishes an event");
                self.offers.fetch_add(1, Ordering::SeqCst);
                let verdict = self.judge(&event);
                let replies = self.carry_out(verdict, event);
                if matches!(replies.first(), Some(Reply::HangUp)) {
                    return None;
                }
                replies
            }
            [verb, sub, filters @ ..] if verb == "REQ" => {
                let filters: Vec<Filter> = filters
                    .iter()
                    .filter_map(|filter| serde_json::from_value(filter.clone()).ok())
                    .collect();
                let eose = || serde_json::json!(["EOSE", sub]).to_string();
                let answers = self.answers.lock().unwrap_or_else(PoisonError::into_inner);
                let scripted = answers
                    .iter()
                    .rev()
                    .find(|(asked, _)| filters.iter().any(asked))
                    .map(|(_, frames)| {
                        frames
                            .iter()
                            .map(|frame| match frame {
                                Frame::Event(event) => Reply::Text(
                                    serde_json::json!(["EVENT", sub, event]).to_string(),
                                ),
                                Frame::Unasked(event) => Reply::Text(
                                    serde_json::json!(["EVENT", "never-opened", event]).to_string(),
                                ),
                                Frame::Raw(event) => {
                                    Reply::Text(format!(r#"["EVENT",{sub},{event}]"#))
                                }
                                Frame::Eose => Reply::Text(eose()),
                                Frame::Closed(text) => Reply::Text(
                                    serde_json::json!(["CLOSED", sub, text]).to_string(),
                                ),
                                Frame::Hold(open) => Reply::Hold(open.clone()),
                            })
                            .collect()
                    });
                drop(answers);
                scripted.unwrap_or_else(|| {
                    let kept = if self.serve_kept.load(Ordering::SeqCst) {
                        self.kept_matching(&filters)
                    } else {
                        Vec::new()
                    };
                    kept.into_iter()
                        .map(|event| {
                            Reply::Text(serde_json::json!(["EVENT", sub, event]).to_string())
                        })
                        .chain(std::iter::once(Reply::Text(eose())))
                        .collect()
                })
            }
            _ => Vec::new(),
        })
    }

    /// What `verdict` does with `event`: the store now, the frames as replies.
    fn carry_out(&self, verdict: Verdict, event: Event) -> Vec<Reply> {
        let keep = |event: Event| {
            self.published
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(event);
        };
        let ok = |accepted: bool, text: &str| {
            Reply::Text(serde_json::json!(["OK", event.id, accepted, text]).to_string())
        };
        match verdict {
            Verdict::Keep => {
                let reply = ok(true, "");
                keep(event);
                vec![reply]
            }
            Verdict::KeepSaying(text) => {
                let reply = ok(true, &text);
                keep(event);
                vec![reply]
            }
            Verdict::Frames(frames) => frames.into_iter().map(Reply::Text).collect(),
            Verdict::Refuse(text) => vec![ok(false, &text)],
            Verdict::KeepSilently => {
                keep(event);
                Vec::new()
            }
            Verdict::HangUp => vec![Reply::HangUp],
            Verdict::HoldThen(open, then) => std::iter::once(Reply::Hold(open))
                .chain(self.carry_out(*then, event))
                .collect(),
        }
    }

    /// The kept events `filters` match, as a NIP-01 relay serves them.
    fn kept_matching(&self, filters: &[Filter]) -> Vec<Event> {
        let mut newest: Vec<Event> = Vec::new();
        for event in self
            .published
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
        {
            let coordinate = |e: &Event| {
                (e.kind.is_replaceable() || e.kind.is_addressable()).then(|| {
                    let d = e.tags.identifier().map(str::to_owned);
                    (e.kind, e.pubkey, d)
                })
            };
            match coordinate(event).and_then(|at| {
                newest
                    .iter()
                    .position(|e| coordinate(e).as_ref() == Some(&at))
            }) {
                Some(i) if (newest[i].created_at, event.id) < (event.created_at, newest[i].id) => {
                    newest[i] = event.clone();
                }
                Some(_) => {}
                None => newest.push(event.clone()),
            }
        }
        newest.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(a.id.cmp(&b.id)));
        let mut served: Vec<Event> = Vec::new();
        for filter in filters {
            let matching = newest.iter().filter(|event| {
                filter.match_event(event, nostr::filter::MatchEventOptions::default())
            });
            for event in matching.take(filter.limit.unwrap_or(usize::MAX)) {
                if !served.contains(event) {
                    served.push(event.clone());
                }
            }
        }
        served
    }
}
