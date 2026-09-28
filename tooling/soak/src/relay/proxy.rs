//! The endpoint the devices actually dial, and the only place a fault can
//! change what a client sees.
//!
//! Every plane puts this in front of its relay, always — not only while a fault
//! is armed. Two things follow from that, and both are the point:
//!
//! * The ledger is a record of the **client-facing** stream. A plane that
//!   answered "was this acked?" from the relay's side would let the rig confirm
//!   a commit whose acknowledgement never left the building (Rule 13).
//! * `Down` closes the endpoint the client dials, so a down plane refuses
//!   connections rather than accepting them and failing behind the curtain,
//!   and `Up` takes the SAME port back — a schedule that moved the URL would
//!   be testing the rig's bookkeeping, not the subject's reconnect.
//!
//! The shape is promoted from `haven-core/tests/catchup_sweep_e2e.rs`'s
//! `TamperedRelay`; this copy is authoritative for the rig, and the test copy
//! stays where it is.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use nostr::{ClientMessage, Event, EventId, JsonUtil, RelayMessage, SubscriptionId};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::JoinHandle;

use crate::nemesis::types::{ClosedPrefix, DropClass, RigCount};
use crate::relay::forge::{take_frame, take_http_head, text_frame, Frame};
use crate::relay::ledger::Ledger;
use crate::relay::policies::{closed_message, oversize_message};
use crate::rig::{poll_until, DeviceTag, RigError, Step};

/// How long `Up` waits for its own port back.
///
/// The accept loop's listener is released when the task owning it is dropped,
/// which `take_down` awaits, so the first attempt normally succeeds; the bound
/// covers the kernel releasing a listening socket and turns the one case that
/// would otherwise hang — a port that never comes back — into a loud failure.
const REBIND_BOUND: Duration = Duration::from_secs(5);
/// How often a rebind retries inside [`REBIND_BOUND`].
const REBIND_EVERY: Duration = Duration::from_millis(20);
/// How much room each read asks for. One page holds any NIP-01 frame the rig
/// sees whole, and a bigger frame simply takes two reads.
const READ_CHUNK: usize = 4096;
/// Forged frames in flight from the client-facing pump to the writer.
const FORGED_DEPTH: usize = 16;
/// Injected frames a connection may fall behind by before it drops the oldest.
const INJECT_DEPTH: usize = 16;
/// The subscription a cross-subscription `EOSE` names. Harness-authored: one
/// pooled connection carries every REQ, so an `EOSE` for a subscription this
/// client never opened is an ordinary sight on a real relay.
const FOREIGN_SUBSCRIPTION: &str = "a-subscription-this-client-never-opened";

/// One `EVENT` frame held back from a page, with the event it carries and its
/// class — read when it is held, because the frame is not re-parsed when a
/// later `EOSE` releases it.
type HeldEvent = (Vec<u8>, EventId, Option<DropClass>);

/// Pages held back under [`FaultState::reverse_pages`] or
/// [`FaultState::clamp_limit`], PER SUBSCRIPTION.
///
/// Per subscription and never per connection: one pooled socket carries every
/// REQ a device makes, so a connection-wide hold releases one subscription's
/// page at another's `EOSE` — and then delivers the rest of it in the order the
/// relay stored it, which is the opposite of the fault. A scenario asserting a
/// reversed page would pass or fail on which subscription's `EOSE` happened to
/// land first.
type HeldPages = HashMap<SubscriptionId, Vec<HeldEvent>>;

/// Holds one event of `subscription`'s page back.
fn hold(held: &mut HeldPages, subscription: SubscriptionId, event: HeldEvent) {
    held.entry(subscription).or_default().push(event);
}

/// Takes the page `subscription`'s `EOSE` releases, leaving every other
/// subscription's alone: cut to the newest `clamp_limit` events, then — under
/// `reverse_pages` — in the reverse of the order the relay served it.
///
/// The relay serves newest first, so the newest `n` are the first `n` it
/// served, which is exactly the page a relay clamping `limit` to `n` would
/// have served (`nostr-relay-builder-0.44.1/src/local/inner.rs:838-857` clamps
/// the filter, then the store answers it). Shaped by the state at the `EOSE`,
/// so a heal that lands mid-page releases the page as the relay served it.
fn release(
    held: &mut HeldPages,
    subscription: &SubscriptionId,
    faults: FaultState,
) -> Vec<HeldEvent> {
    let mut page = held.remove(subscription).unwrap_or_default();
    if let Some(n) = faults.clamp_limit {
        page.truncate(n);
    }
    if faults.reverse_pages {
        page.reverse();
    }
    page
}

/// Where [`RefusedPage::arming`] comes from: a fresh value per arming, so a
/// connection counts its `REQ`s from the arming it sees and never from its
/// own first `REQ`.
static ARMINGS: AtomicU64 = AtomicU64::new(1);

/// A [`FaultState::refuse_page`] armed now, refusing the `nth` `REQ`.
pub fn arm_refuse_page(nth: RigCount) -> RefusedPage {
    RefusedPage {
        nth: nth.get(),
        arming: ARMINGS.fetch_add(1, Ordering::Relaxed),
    }
}

/// Which `REQ` a connection refuses, and which arming that count belongs to.
#[derive(Clone, Copy)]
pub struct RefusedPage {
    nth: usize,
    arming: u64,
}

/// The `REQ`s one connection has made under the current arming.
///
/// Per connection because a relay's page is per connection, and per ARMING
/// because the fault is armed mid-run: counted from the connection's own first
/// `REQ`, a pooled socket that had already made `nth` would never be refused.
#[derive(Default)]
struct ReqCount {
    arming: u64,
    seen: usize,
}

impl ReqCount {
    /// Counts one `REQ`; whether it is the one `armed` refuses.
    const fn refuses(&mut self, armed: Option<RefusedPage>) -> bool {
        let Some(armed) = armed else {
            return false;
        };
        if armed.arming != self.arming {
            self.arming = armed.arming;
            self.seen = 0;
        }
        self.seen += 1;
        self.seen == armed.nth
    }
}

/// What is currently wrong with a plane's client-facing stream.
///
/// `Copy`, and read once per frame: a fault must be able to change mid-run
/// without restarting the relay, and holding a lock across a write would make
/// one slow client stall another.
#[derive(Clone, Copy, Default)]
// The proxy faults are independent by construction — a schedule may arm any
// subset at once — so folding them into a state machine would assert an
// ordering the nemesis does not have.
#[allow(clippy::struct_excessive_bools)]
pub struct FaultState {
    pub swallow_ok: bool,
    pub double_events: bool,
    pub reverse_pages: bool,
    pub cross_eose: bool,
    pub closed: Option<ClosedPrefix>,
    /// The largest `EVENT` this plane forwards, when one is capped.
    pub max_event_bytes: Option<usize>,
    /// The class of `EVENT` frame this endpoint withholds, when one is.
    pub drop_class: Option<DropClass>,
    /// The most events a stored-event page carries, when pages are clamped.
    pub clamp_limit: Option<usize>,
    /// The `REQ` each connection has refused, when one is.
    pub refuse_page: Option<RefusedPage>,
    /// Whether the next connection this endpoint accepts is dropped.
    pub cold_first_connect: bool,
}

impl FaultState {
    /// Whether an `EVENT` frame of `class` is withheld by this state.
    fn drops(self, class: Option<DropClass>) -> bool {
        self.drop_class.is_some() && self.drop_class == class
    }
}

/// The listening half of a plane: one endpoint, canonical or a device's own.
pub struct Proxy {
    url: String,
    addr: SocketAddr,
    target: String,
    /// Whose endpoint this is. `None` is the plane's canonical one — circles,
    /// key packages and catch-up dial it — and the ledger records every
    /// delivery under this key, which is the device dimension a partition arm
    /// reads back.
    device: Option<DeviceTag>,
    state: Arc<RwLock<FaultState>>,
    ledger: Ledger,
    /// Bumped to cancel every live connection. Held behind an `Arc` so the
    /// accept loop can mint a receiver PER CONNECTION: a receiver cloned before
    /// a bump would see that bump and kill a connection accepted after it.
    generation: Arc<watch::Sender<u64>>,
    inject: broadcast::Sender<String>,
    accept: Option<JoinHandle<()>>,
}

impl Proxy {
    /// Binds a loopback endpoint in front of `relay_url` and starts accepting.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ApplyFault`] if the endpoint cannot be
    /// bound — a plane with no address is not a plane.
    pub async fn start(
        relay_url: &str,
        ledger: Ledger,
        device: Option<DeviceTag>,
    ) -> Result<Self, RigError> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(|_| RigError::Core(Step::ApplyFault))?;
        let addr = listener
            .local_addr()
            .map_err(|_| RigError::Core(Step::ApplyFault))?;
        let (generation, _) = watch::channel(0);
        let (inject, _) = broadcast::channel(INJECT_DEPTH);
        let mut proxy = Self {
            url: format!("ws://{addr}"),
            addr,
            target: relay_url
                .trim_start_matches("ws://")
                .trim_end_matches('/')
                .to_string(),
            device,
            state: Arc::new(RwLock::new(FaultState::default())),
            ledger,
            generation: Arc::new(generation),
            inject,
            accept: None,
        };
        proxy.serve_on(listener);
        Ok(proxy)
    }

    /// The `ws://` address devices dial.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// Whether the endpoint is accepting connections.
    pub const fn is_up(&self) -> bool {
        self.accept.is_some()
    }

    /// Changes what is wrong with the stream, effective on the next frame.
    pub fn edit(&self, change: impl FnOnce(&mut FaultState)) {
        let mut state = self.state.write().unwrap_or_else(PoisonError::into_inner);
        change(&mut state);
    }

    /// Closes the endpoint and drops every live connection.
    ///
    /// Awaits the accept task so the listener is released before returning:
    /// `Down` then `Up` is a sequence the schedule may apply back to back, and
    /// a rebind racing an undropped listener would be an `EADDRINUSE` flake in
    /// the rig rather than a finding about the subject.
    pub async fn take_down(&mut self) {
        if let Some(accept) = self.accept.take() {
            accept.abort();
            let _ = accept.await;
        }
        self.generation.send_modify(|generation| *generation += 1);
    }

    /// Takes the same port back, retrying inside [`REBIND_BOUND`].
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ApplyFault`] if the port never came
    /// back: a plane that healed onto a different address would prove nothing
    /// about a client's reconnect.
    pub async fn bring_up(&mut self) -> Result<(), RigError> {
        if self.is_up() {
            return Ok(());
        }
        let attempts = AtomicU32::new(0);
        let bound: Mutex<Option<TcpListener>> = Mutex::new(None);
        let addr = self.addr;
        let waited = poll_until(REBIND_BOUND, REBIND_EVERY, || {
            let attempts = &attempts;
            let bound = &bound;
            async move {
                attempts.fetch_add(1, Ordering::Relaxed);
                (TcpListener::bind(addr).await).map_or(Ok(false), |listener| {
                    *bound.lock().unwrap_or_else(PoisonError::into_inner) = Some(listener);
                    Ok(true)
                })
            }
        })
        .await?;
        let (Some(waited), Some(listener)) = (
            waited,
            bound.lock().unwrap_or_else(PoisonError::into_inner).take(),
        ) else {
            return Err(RigError::Core(Step::ApplyFault));
        };
        self.ledger
            .note_rebind(attempts.load(Ordering::Relaxed), waited);
        self.serve_on(listener);
        Ok(())
    }

    /// Sends a `NOTICE` to every live connection.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ApplyFault`] if nothing is connected: a
    /// notice nobody received did not happen, and a bound derived from a fault
    /// that never fired is a fiction.
    pub fn notice(&self, text: &'static str) -> Result<(), RigError> {
        self.inject
            .send(RelayMessage::Notice(Cow::Borrowed(text)).as_json())
            .map(|_| ())
            .map_err(|_| RigError::Core(Step::ApplyFault))
    }

    /// Writes `forged` onto this endpoint's live connections — on each one,
    /// once per subscription in `matching` that THAT connection opened — and
    /// never saves it.
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`Step::ApplyFault`] if nothing is connected
    /// here: an injection nobody received did not happen.
    pub fn broadcast_event(
        &self,
        forged: &Event,
        matching: &[SubscriptionId],
    ) -> Result<(), RigError> {
        for subscription_id in matching {
            self.inject
                .send(
                    RelayMessage::Event {
                        subscription_id: Cow::Borrowed(subscription_id),
                        event: Cow::Borrowed(forged),
                    }
                    .as_json(),
                )
                .map_err(|_| RigError::Core(Step::ApplyFault))?;
        }
        Ok(())
    }

    fn serve_on(&mut self, listener: TcpListener) {
        let target = self.target.clone();
        let device = self.device;
        let state = Arc::clone(&self.state);
        let ledger = self.ledger.clone();
        let generation = Arc::clone(&self.generation);
        let inject = self.inject.clone();
        self.accept = Some(tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                if refuses_connect(&state) {
                    // Closed before the upgrade head is read: the client's
                    // handshake fails the way a relay that is still starting
                    // fails it, and nothing reaches the relay behind.
                    drop(client);
                    ledger.note_refused_connect();
                    continue;
                }
                tokio::spawn(serve(
                    client,
                    target.clone(),
                    device,
                    Arc::clone(&state),
                    ledger.clone(),
                    generation.subscribe(),
                    inject.subscribe(),
                ));
            }
        }));
    }
}

/// Whether this accept is the one [`FaultState::cold_first_connect`] refuses,
/// consuming the fault so exactly one is.
fn refuses_connect(state: &RwLock<FaultState>) -> bool {
    let mut state = state.write().unwrap_or_else(PoisonError::into_inner);
    std::mem::take(&mut state.cold_first_connect)
}

// The accept task owns the listener, so the endpoint stays bound until the task
// is dropped; live connections end when the last `generation` sender goes with
// it.
impl Drop for Proxy {
    fn drop(&mut self) {
        if let Some(accept) = self.accept.take() {
            accept.abort();
        }
    }
}

/// Pipes one client connection to the relay until either end closes or the
/// plane goes down.
async fn serve(
    client: TcpStream,
    target: String,
    device: Option<DeviceTag>,
    state: Arc<RwLock<FaultState>>,
    ledger: Ledger,
    mut cancel: watch::Receiver<u64>,
    inject: broadcast::Receiver<String>,
) {
    let Ok(relay) = TcpStream::connect(&target).await else {
        return;
    };
    let (from_client, to_client) = client.into_split();
    let (from_relay, to_relay) = relay.into_split();
    let (forged_tx, forged_rx) = mpsc::channel(FORGED_DEPTH);
    // The subscriptions THIS connection opened. An injection is delivered by
    // the relay's rule — onto every open subscription its filter matches — but
    // a subscription is open on one connection, and the pool on the other end
    // notifies an event ONCE per id: a forged frame carrying somebody else's
    // subscription id would burn that one notification on a REQ this client
    // never opened, and the engine behind it would never see the injection.
    let subscriptions: Arc<Mutex<Subscriptions>> = Arc::default();

    let mut upstream = tokio::spawn(pump_to_relay(
        from_client,
        to_relay,
        Arc::clone(&state),
        ledger.clone(),
        forged_tx,
        Arc::clone(&subscriptions),
    ));
    let connection = Connection {
        device,
        state,
        ledger,
        subscriptions,
    };
    let mut downstream = tokio::spawn(pump_to_client(
        from_relay, to_client, connection, forged_rx, inject,
    ));

    tokio::select! {
        _ = &mut upstream => {}
        _ = &mut downstream => {}
        _ = cancel.changed() => {}
    }
    upstream.abort();
    downstream.abort();
}

/// Client → relay: records what the client sent, and answers a `REQ` itself
/// when the plane is refusing subscriptions.
async fn pump_to_relay(
    mut from_client: OwnedReadHalf,
    mut to_relay: OwnedWriteHalf,
    state: Arc<RwLock<FaultState>>,
    ledger: Ledger,
    forged: mpsc::Sender<String>,
    subscriptions: Arc<Mutex<Subscriptions>>,
) {
    if !forward_head(&mut from_client, &mut to_relay).await {
        return;
    }
    let mut buf = Vec::new();
    let mut reqs = ReqCount::default();
    loop {
        while let Some(frame) = take_frame(&mut buf) {
            let upstream = Upstream {
                state: &state,
                ledger: &ledger,
                forged: &forged,
                subscriptions: &subscriptions,
            };
            if !forward_from_client(&frame, &mut to_relay, upstream, &mut reqs).await {
                return;
            }
        }
        if read_more(&mut from_client, &mut buf).await.is_none() {
            return;
        }
    }
}

/// Relay → client: applies the client-facing faults and records every frame
/// that really went out.
async fn pump_to_client(
    mut from_relay: OwnedReadHalf,
    mut to_client: OwnedWriteHalf,
    connection: Connection,
    mut forged: mpsc::Receiver<String>,
    mut inject: broadcast::Receiver<String>,
) {
    // The 101 response is not framed, and nothing may be injected before it:
    // a forged frame ahead of the handshake would corrupt it.
    if !forward_head(&mut from_relay, &mut to_client).await {
        return;
    }
    let mut buf = Vec::new();
    let mut held = HeldPages::new();
    let endpoint = Endpoint {
        device: connection.device,
        state: &connection.state,
        ledger: &connection.ledger,
        subscriptions: &connection.subscriptions,
    };
    loop {
        while let Some(frame) = take_frame(&mut buf) {
            if !deliver(&frame, &mut to_client, endpoint, &mut held).await {
                return;
            }
        }
        tokio::select! {
            read = read_more(&mut from_relay, &mut buf) => {
                if read.is_none() {
                    return;
                }
            }
            message = forged.recv() => {
                let Some(json) = message else { return };
                if !write_forged(&json, &mut to_client, endpoint).await {
                    return;
                }
            }
            message = inject.recv() => match message {
                Ok(json) => {
                    if !write_forged(&json, &mut to_client, endpoint).await {
                        return;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return,
            },
        }
    }
}

/// Copies one side's HTTP upgrade head through, up to and including the blank
/// line that ends it. Whatever arrived after it is left for the framing loop.
async fn forward_head(from: &mut OwnedReadHalf, to: &mut OwnedWriteHalf) -> bool {
    let mut buf = Vec::new();
    loop {
        if let Some(head) = take_http_head(&mut buf) {
            return to.write_all(&head).await.is_ok();
        }
        if read_more(from, &mut buf).await.is_none() {
            return false;
        }
    }
}

/// Reads whatever is available, or `None` at end of stream.
async fn read_more(from: &mut OwnedReadHalf, buf: &mut Vec<u8>) -> Option<usize> {
    // Without spare capacity a buffered read reports zero bytes, which reads
    // exactly like an end of stream.
    buf.reserve(READ_CHUNK);
    match from.read_buf(buf).await {
        Ok(0) | Err(_) => None,
        Ok(read) => Some(read),
    }
}

/// The client→relay side of one connection: what is wrong with it, where its
/// frames are recorded, where a forged answer goes, and what it has open.
#[derive(Clone, Copy)]
struct Upstream<'a> {
    state: &'a RwLock<FaultState>,
    ledger: &'a Ledger,
    forged: &'a mpsc::Sender<String>,
    subscriptions: &'a Mutex<Subscriptions>,
}

/// The subscriptions one connection holds.
#[derive(Default)]
struct Subscriptions {
    /// Opened and not closed.
    open: HashSet<SubscriptionId>,
    /// Forwarded and not yet answered with `EOSE`: an `EVENT` for one of these
    /// is a stored-event page, and any other is a live delivery.
    paging: HashSet<SubscriptionId>,
}

async fn forward_from_client(
    frame: &Frame,
    to_relay: &mut OwnedWriteHalf,
    upstream: Upstream<'_>,
    reqs: &mut ReqCount,
) -> bool {
    let Upstream {
        state,
        ledger,
        forged,
        subscriptions,
    } = upstream;
    if frame.is_text() {
        if let Ok(message) = ClientMessage::from_json(frame.payload().as_ref()) {
            let faults = *state.read().unwrap_or_else(PoisonError::into_inner);
            match message {
                ClientMessage::Event(event) => {
                    ledger.note_published(event.id);
                    if oversize(&event, faults) {
                        // Refused on the way OUT, so the relay never sees it:
                        // a plane that both stored the event and told the
                        // client it was too large would let an arm pass on the
                        // store.
                        return forged
                            .send(
                                RelayMessage::Ok {
                                    event_id: event.id,
                                    status: false,
                                    message: Cow::Owned(oversize_message()),
                                }
                                .as_json(),
                            )
                            .await
                            .is_ok();
                    }
                }
                ClientMessage::Req {
                    subscription_id,
                    filters,
                } => {
                    let subscription_id = subscription_id.into_owned();
                    ledger.note_req(
                        subscription_id.clone(),
                        filters.into_iter().map(Cow::into_owned).collect(),
                    );
                    if let Some(prefix) = faults.closed {
                        // A refused REQ never reaches the relay: a relay that
                        // both served the page and closed the subscription
                        // would let a scenario pass on the page.
                        return forged
                            .send(
                                RelayMessage::Closed {
                                    subscription_id: Cow::Owned(subscription_id),
                                    message: Cow::Owned(closed_message(prefix)),
                                }
                                .as_json(),
                            )
                            .await
                            .is_ok();
                    }
                    if reqs.refuses(faults.refuse_page) {
                        // The relay's own `QueryPolicy` rejection, forged:
                        // `CLOSED "error: …"` and no page at all.
                        return forged
                            .send(
                                RelayMessage::Closed {
                                    subscription_id: Cow::Owned(subscription_id),
                                    message: Cow::Owned(closed_message(ClosedPrefix::Error)),
                                }
                                .as_json(),
                            )
                            .await
                            .is_ok();
                    }
                    {
                        let mut held = subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
                        held.open.insert(subscription_id.clone());
                        // Before the REQ is forwarded, so no frame of its page
                        // can arrive ahead of the mark.
                        held.paging.insert(subscription_id);
                    }
                    if faults.cross_eose
                        && forged
                            .send(
                                RelayMessage::EndOfStoredEvents(Cow::Owned(SubscriptionId::new(
                                    FOREIGN_SUBSCRIPTION,
                                )))
                                .as_json(),
                            )
                            .await
                            .is_err()
                    {
                        return false;
                    }
                }
                ClientMessage::Close(subscription_id) => {
                    let mut held = subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
                    held.open.remove(subscription_id.as_ref());
                    held.paging.remove(subscription_id.as_ref());
                }
                _ => {}
            }
        }
    }
    to_relay.write_all(frame.bytes()).await.is_ok()
}

/// What one connection's client-facing pump owns: the same four things
/// [`Endpoint`] borrows, held for the life of the socket.
struct Connection {
    device: Option<DeviceTag>,
    state: Arc<RwLock<FaultState>>,
    ledger: Ledger,
    subscriptions: Arc<Mutex<Subscriptions>>,
}

/// The client-facing side of one connection: whose endpoint it is, what is
/// wrong with it, and where its frames are recorded.
#[derive(Clone, Copy)]
struct Endpoint<'a> {
    device: Option<DeviceTag>,
    state: &'a RwLock<FaultState>,
    ledger: &'a Ledger,
    /// The subscriptions this connection opened and has not closed.
    subscriptions: &'a Mutex<Subscriptions>,
}

impl Endpoint<'_> {
    fn faults(self) -> FaultState {
        *self.state.read().unwrap_or_else(PoisonError::into_inner)
    }

    fn opened(self, subscription_id: &SubscriptionId) -> bool {
        self.subscriptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .open
            .contains(subscription_id)
    }

    fn paging(self, subscription_id: &SubscriptionId) -> bool {
        self.subscriptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .paging
            .contains(subscription_id)
    }

    fn page_ended(self, subscription_id: &SubscriptionId) {
        self.subscriptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .paging
            .remove(subscription_id);
    }
}

async fn deliver(
    frame: &Frame,
    to_client: &mut OwnedWriteHalf,
    endpoint: Endpoint<'_>,
    held: &mut HeldPages,
) -> bool {
    let ledger = endpoint.ledger;
    if frame.is_text() {
        if let Ok(message) = RelayMessage::from_json(frame.payload().as_ref()) {
            let faults = endpoint.faults();
            match message {
                RelayMessage::Ok {
                    event_id,
                    status,
                    message,
                } => {
                    if faults.swallow_ok {
                        // The relay has it and said so; the client never hears
                        // it. Recording it here would defeat the fault.
                        return true;
                    }
                    if !write(to_client, frame.bytes()).await {
                        return false;
                    }
                    ledger.note_ok(event_id, status, &message);
                    return true;
                }
                RelayMessage::Event {
                    subscription_id,
                    event,
                } => {
                    let class = DropClass::of(&event);
                    if faults.reverse_pages
                        || (faults.clamp_limit.is_some() && endpoint.paging(&subscription_id))
                    {
                        hold(
                            held,
                            subscription_id.into_owned(),
                            (frame.bytes().to_vec(), event.id, class),
                        );
                        return true;
                    }
                    return write_event(to_client, frame.bytes(), (event.id, class), endpoint)
                        .await;
                }
                RelayMessage::EndOfStoredEvents(subscription_id) => {
                    endpoint.page_ended(subscription_id.as_ref());
                    for (bytes, event_id, class) in release(held, subscription_id.as_ref(), faults)
                    {
                        if !write_event(to_client, &bytes, (event_id, class), endpoint).await {
                            return false;
                        }
                    }
                    if !write(to_client, frame.bytes()).await {
                        return false;
                    }
                    ledger.note_eose();
                    return true;
                }
                RelayMessage::Closed { message, .. } => {
                    if !write(to_client, frame.bytes()).await {
                        return false;
                    }
                    ledger.note_closed(message.into_owned());
                    return true;
                }
                RelayMessage::Notice(text) => {
                    if !write(to_client, frame.bytes()).await {
                        return false;
                    }
                    ledger.note_notice(text.into_owned());
                    return true;
                }
                _ => {}
            }
        }
    }
    write(to_client, frame.bytes()).await
}

/// Whether this `EVENT` is over the plane's cap.
///
/// The EVENT's own JSON, not the frame's: that is what a relay's size limit
/// measures, and it is the quantity an arm can take off an event it has staged
/// but not yet published. The `["EVENT", …]` envelope belongs to the transport.
fn oversize(event: &Event, faults: FaultState) -> bool {
    faults
        .max_event_bytes
        .is_some_and(|cap| event.as_json().len() > cap)
}

/// Writes a forged frame and records it exactly as a relay-sent one would be.
///
/// An injected `EVENT` is subject to the endpoint's dropped class like any
/// other: the partition is between the relay's side of the proxy and this
/// socket, and a frame the plane composed crosses the same socket.
///
/// And it is written only for a subscription THIS connection opened: the plane
/// broadcasts one frame per matching subscription to every connection, and a
/// frame naming a subscription some other connection holds is one the client
/// on this socket never asked for — worse, a pool notifies an event once per
/// id, so that frame would spend the notification the client's own
/// subscription was owed.
async fn write_forged(json: &str, to_client: &mut OwnedWriteHalf, endpoint: Endpoint<'_>) -> bool {
    let ledger = endpoint.ledger;
    let message = RelayMessage::from_json(json).ok();
    if let Some(RelayMessage::Event {
        subscription_id,
        event,
    }) = &message
    {
        if !endpoint.opened(subscription_id) || endpoint.faults().drops(DropClass::of(event)) {
            return true;
        }
    }
    if !write(to_client, &text_frame(json.as_bytes())).await {
        return false;
    }
    match message {
        Some(RelayMessage::Closed { message, .. }) => ledger.note_closed(message.into_owned()),
        Some(RelayMessage::Notice(text)) => ledger.note_notice(text.into_owned()),
        Some(RelayMessage::EndOfStoredEvents(_)) => ledger.note_eose(),
        Some(RelayMessage::Ok {
            event_id,
            status,
            message,
        }) => ledger.note_ok(event_id, status, &message),
        // An injected `EVENT` is recorded as a delivery like any other: it
        // really went out, and the ledger is the record of what the client was
        // sent, not of who composed it.
        Some(RelayMessage::Event { event, .. }) => {
            ledger.note_delivered(endpoint.device, event.id);
        }
        _ => {}
    }
    true
}

/// Writes one `EVENT` frame towards the client — twice under a doubling fault,
/// never under a fault dropping its class — and records what went out.
async fn write_event(
    to_client: &mut OwnedWriteHalf,
    bytes: &[u8],
    (event_id, class): (EventId, Option<DropClass>),
    endpoint: Endpoint<'_>,
) -> bool {
    let faults = endpoint.faults();
    if faults.drops(class) {
        // Not recorded: the frame never went out, and a ledger that counted
        // it would hand the partition arm the delivery it is asserting away.
        return true;
    }
    let copies = if faults.double_events { 2 } else { 1 };
    for _ in 0..copies {
        if !write(to_client, bytes).await {
            return false;
        }
        endpoint.ledger.note_delivered(endpoint.device, event_id);
    }
    true
}

async fn write(to_client: &mut OwnedWriteHalf, bytes: &[u8]) -> bool {
    to_client.write_all(bytes).await.is_ok()
}

#[cfg(test)]
mod tests {
    use super::{arm_refuse_page, hold, release, FaultState, HeldEvent, HeldPages, ReqCount};
    use crate::nemesis::types::RigCount;
    use nostr::{EventId, SubscriptionId};

    fn reversing() -> FaultState {
        FaultState {
            reverse_pages: true,
            ..FaultState::default()
        }
    }

    fn an_event(byte: u8) -> HeldEvent {
        (
            vec![byte],
            EventId::from_slice(&[byte; 32]).expect("32 bytes is an event id"),
            None,
        )
    }

    #[test]
    fn a_state_drops_exactly_the_class_it_was_armed_with() {
        use crate::nemesis::types::DropClass;

        let state = FaultState {
            drop_class: Some(DropClass::Application),
            ..FaultState::default()
        };
        assert!(state.drops(Some(DropClass::Application)));
        assert!(!state.drops(Some(DropClass::Handshake)));
        assert!(
            !state.drops(None),
            "a frame no class names is never dropped, whatever class is armed"
        );
        assert!(
            !FaultState::default().drops(Some(DropClass::Application)),
            "an unarmed state drops nothing, and `None == None` must not read as a match"
        );
    }

    #[test]
    fn a_page_is_released_by_its_own_subscriptions_eose_and_no_other() {
        // The interleaving a device really produces: one pooled socket, two
        // subscriptions, and the second one's page ending in the middle of the
        // first one's. A connection-wide hold releases everything held at THAT
        // moment — which is the first subscription's page, in the order the
        // relay stored it, with the rest of it still to come.
        let mut held = HeldPages::new();
        let first = SubscriptionId::new("first");
        let second = SubscriptionId::new("second");

        hold(&mut held, first.clone(), an_event(1));
        hold(&mut held, first.clone(), an_event(2));
        hold(&mut held, second.clone(), an_event(9));
        hold(&mut held, first.clone(), an_event(3));

        let stranger = release(&mut held, &second, reversing());
        assert_eq!(
            stranger,
            vec![an_event(9)],
            "one subscription's EOSE released another's page"
        );

        let page = release(&mut held, &first, reversing());
        assert_eq!(
            page,
            vec![an_event(3), an_event(2), an_event(1)],
            "a page released by its own EOSE must carry every event it held, newest first"
        );
        assert!(
            release(&mut held, &first, reversing()).is_empty(),
            "a page is released once; a second EOSE has nothing to deliver"
        );
    }

    #[test]
    fn a_subscription_that_held_nothing_releases_nothing() {
        let mut held = HeldPages::new();
        assert!(release(&mut held, &SubscriptionId::new("quiet"), reversing()).is_empty());
        hold(&mut held, SubscriptionId::new("loud"), an_event(1));
        assert!(
            release(&mut held, &SubscriptionId::new("quiet"), reversing()).is_empty(),
            "an EOSE for a subscription this connection never carried takes nobody's page"
        );
    }

    #[test]
    fn a_clamped_page_keeps_the_newest_events_in_the_relays_order_and_reverses_after_the_cut() {
        let page = || {
            let mut held = HeldPages::new();
            // Held in the order the relay served them: newest first.
            for byte in 1..=4 {
                hold(&mut held, SubscriptionId::new("page"), an_event(byte));
            }
            held
        };
        let clamped = FaultState {
            clamp_limit: Some(2),
            ..FaultState::default()
        };
        assert_eq!(
            release(&mut page(), &SubscriptionId::new("page"), clamped),
            vec![an_event(1), an_event(2)],
            "a clamp keeps the first events the relay served, which are its newest"
        );
        assert_eq!(
            release(
                &mut page(),
                &SubscriptionId::new("page"),
                FaultState {
                    reverse_pages: true,
                    ..clamped
                }
            ),
            vec![an_event(2), an_event(1)],
            "both armed, the page is cut first and reversed after: reversing first would keep the oldest"
        );
        assert_eq!(
            release(
                &mut page(),
                &SubscriptionId::new("page"),
                FaultState::default()
            )
            .len(),
            4,
            "a page held under a fault healed before its EOSE is released whole, as served"
        );
    }

    #[test]
    fn a_refused_page_is_the_nth_req_after_the_arming_and_no_other() {
        let mut reqs = ReqCount::default();
        assert!(!reqs.refuses(None), "nothing armed refuses nothing");
        assert!(!reqs.refuses(None));

        // Two REQs already made on this connection do not count towards it.
        let armed = Some(arm_refuse_page(RigCount::new(2)));
        assert!(
            !reqs.refuses(armed),
            "the first REQ after the arming is served"
        );
        assert!(reqs.refuses(armed), "the second is refused");
        assert!(!reqs.refuses(armed), "and only the second");

        let rearmed = Some(arm_refuse_page(RigCount::new(1)));
        assert!(
            reqs.refuses(rearmed),
            "a fresh arming counts afresh, whatever the connection made before it"
        );
    }
}
