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
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use nostr::{ClientMessage, EventId, JsonUtil, RelayMessage, SubscriptionId};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::JoinHandle;

use crate::nemesis::types::ClosedPrefix;
use crate::relay::forge::{take_frame, take_http_head, text_frame, Frame};
use crate::relay::ledger::Ledger;
use crate::relay::policies::closed_message;
use crate::rig::{poll_until, RigError, Step};

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

/// One `EVENT` frame held back from a page, with the event it carries.
type HeldEvent = (Vec<u8>, EventId);

/// Pages held back under [`FaultState::reverse_pages`], PER SUBSCRIPTION.
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

/// Takes the page `subscription`'s `EOSE` releases, newest first, leaving every
/// other subscription's alone.
fn release(held: &mut HeldPages, subscription: &SubscriptionId) -> Vec<HeldEvent> {
    let mut page = held.remove(subscription).unwrap_or_default();
    page.reverse();
    page
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
}

/// The listening half of a plane.
pub struct Proxy {
    url: String,
    addr: SocketAddr,
    target: String,
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
    pub async fn start(relay_url: &str, ledger: Ledger) -> Result<Self, RigError> {
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

    fn serve_on(&mut self, listener: TcpListener) {
        let target = self.target.clone();
        let state = Arc::clone(&self.state);
        let ledger = self.ledger.clone();
        let generation = Arc::clone(&self.generation);
        let inject = self.inject.clone();
        self.accept = Some(tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                tokio::spawn(serve(
                    client,
                    target.clone(),
                    Arc::clone(&state),
                    ledger.clone(),
                    generation.subscribe(),
                    inject.subscribe(),
                ));
            }
        }));
    }
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

    let mut upstream = tokio::spawn(pump_to_relay(
        from_client,
        to_relay,
        Arc::clone(&state),
        ledger.clone(),
        forged_tx,
    ));
    let mut downstream = tokio::spawn(pump_to_client(
        from_relay, to_client, state, ledger, forged_rx, inject,
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
) {
    if !forward_head(&mut from_client, &mut to_relay).await {
        return;
    }
    let mut buf = Vec::new();
    loop {
        while let Some(frame) = take_frame(&mut buf) {
            if !forward_from_client(&frame, &mut to_relay, &state, &ledger, &forged).await {
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
    state: Arc<RwLock<FaultState>>,
    ledger: Ledger,
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
    loop {
        while let Some(frame) = take_frame(&mut buf) {
            if !deliver(&frame, &mut to_client, &state, &ledger, &mut held).await {
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
                if !write_forged(&json, &mut to_client, &ledger).await {
                    return;
                }
            }
            message = inject.recv() => match message {
                Ok(json) => {
                    if !write_forged(&json, &mut to_client, &ledger).await {
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

async fn forward_from_client(
    frame: &Frame,
    to_relay: &mut OwnedWriteHalf,
    state: &RwLock<FaultState>,
    ledger: &Ledger,
    forged: &mpsc::Sender<String>,
) -> bool {
    if frame.is_text() {
        if let Ok(message) = ClientMessage::from_json(frame.payload().as_ref()) {
            let faults = *state.read().unwrap_or_else(PoisonError::into_inner);
            match message {
                ClientMessage::Event(event) => ledger.note_published(event.id),
                ClientMessage::Req {
                    subscription_id, ..
                } => {
                    let subscription_id = subscription_id.into_owned();
                    ledger.note_req(subscription_id.clone());
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
                _ => {}
            }
        }
    }
    to_relay.write_all(frame.bytes()).await.is_ok()
}

async fn deliver(
    frame: &Frame,
    to_client: &mut OwnedWriteHalf,
    state: &RwLock<FaultState>,
    ledger: &Ledger,
    held: &mut HeldPages,
) -> bool {
    if frame.is_text() {
        if let Ok(message) = RelayMessage::from_json(frame.payload().as_ref()) {
            let faults = *state.read().unwrap_or_else(PoisonError::into_inner);
            match message {
                RelayMessage::Ok {
                    event_id, status, ..
                } => {
                    if faults.swallow_ok {
                        // The relay has it and said so; the client never hears
                        // it. Recording it here would defeat the fault.
                        return true;
                    }
                    if !write(to_client, frame.bytes()).await {
                        return false;
                    }
                    ledger.note_ok(event_id, status);
                    return true;
                }
                RelayMessage::Event {
                    subscription_id,
                    event,
                } => {
                    if faults.reverse_pages {
                        hold(
                            held,
                            subscription_id.into_owned(),
                            (frame.bytes().to_vec(), event.id),
                        );
                        return true;
                    }
                    return write_event(to_client, frame.bytes(), event.id, faults, ledger).await;
                }
                RelayMessage::EndOfStoredEvents(subscription_id) => {
                    for (bytes, event_id) in release(held, subscription_id.as_ref()) {
                        if !write_event(to_client, &bytes, event_id, faults, ledger).await {
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

/// Writes a forged frame and records it exactly as a relay-sent one would be.
async fn write_forged(json: &str, to_client: &mut OwnedWriteHalf, ledger: &Ledger) -> bool {
    if !write(to_client, &text_frame(json.as_bytes())).await {
        return false;
    }
    match RelayMessage::from_json(json) {
        Ok(RelayMessage::Closed { message, .. }) => ledger.note_closed(message.into_owned()),
        Ok(RelayMessage::Notice(text)) => ledger.note_notice(text.into_owned()),
        Ok(RelayMessage::EndOfStoredEvents(_)) => ledger.note_eose(),
        _ => {}
    }
    true
}

async fn write_event(
    to_client: &mut OwnedWriteHalf,
    bytes: &[u8],
    event_id: EventId,
    faults: FaultState,
    ledger: &Ledger,
) -> bool {
    let copies = if faults.double_events { 2 } else { 1 };
    for _ in 0..copies {
        if !write(to_client, bytes).await {
            return false;
        }
        ledger.note_delivered(event_id);
    }
    true
}

async fn write(to_client: &mut OwnedWriteHalf, bytes: &[u8]) -> bool {
    to_client.write_all(bytes).await.is_ok()
}

#[cfg(test)]
mod tests {
    use super::{hold, release, HeldPages};
    use nostr::{EventId, SubscriptionId};

    fn an_event(byte: u8) -> (Vec<u8>, EventId) {
        (
            vec![byte],
            EventId::from_slice(&[byte; 32]).expect("32 bytes is an event id"),
        )
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

        let stranger = release(&mut held, &second);
        assert_eq!(
            stranger,
            vec![an_event(9)],
            "one subscription's EOSE released another's page"
        );

        let page = release(&mut held, &first);
        assert_eq!(
            page,
            vec![an_event(3), an_event(2), an_event(1)],
            "a page released by its own EOSE must carry every event it held, newest first"
        );
        assert!(
            release(&mut held, &first).is_empty(),
            "a page is released once; a second EOSE has nothing to deliver"
        );
    }

    #[test]
    fn a_subscription_that_held_nothing_releases_nothing() {
        let mut held = HeldPages::new();
        assert!(release(&mut held, &SubscriptionId::new("quiet")).is_empty());
        hold(&mut held, SubscriptionId::new("loud"), an_event(1));
        assert!(
            release(&mut held, &SubscriptionId::new("quiet")).is_empty(),
            "an EOSE for a subscription this connection never carried takes nobody's page"
        );
    }
}
