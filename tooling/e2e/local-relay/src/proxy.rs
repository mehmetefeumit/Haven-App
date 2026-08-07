//! The transparent, recording WebSocket proxy.
//!
//! # Routes, not a single upstream
//!
//! The proxy binds one listener per ROUTE (`listen port -> upstream relay`),
//! and every route shares one journal and one `wire_seq` space. That is what
//! makes an endpoint-level assertion possible in a lane with more than one
//! relay (the relay-customization lane runs two): the alternative — one proxy
//! process per relay, each with its own journal — would give each file its own
//! sequence space, and no consumer could establish a total order across them.
//!
//! Every accepted connection opens its own upstream socket, so relay-side
//! per-connection state (subscriptions, NIP-42 AUTH challenges) behaves
//! exactly as it would without the proxy in the path.
//!
//! # What is recorded
//!
//! Text and Binary messages, in both directions, plus a `conn_open` /
//! `conn_error` lifecycle record per connection. WebSocket CONTROL frames
//! (Ping/Pong/Close) are forwarded but NOT recorded: they carry no Nostr
//! payload, and a journal in which every keepalive appears as `frame: null`
//! would bury the unparseable-frame signal — which is a finding — under
//! routine noise.
//!
//! # Errors are logged by KIND, never interpolated
//!
//! Security Rules 6 and 8: a transport error's message can carry
//! remote-authored text (a relay's NOTICE, a rejected URL, an HTTP body). The
//! proxy logs a fixed label instead, so its own log can never become a
//! channel.
//!
//! # A recorded frame is a SENT frame — or the journal says otherwise
//!
//! Each direction's socket is owned by one writer task fed over a channel, and
//! the journal line is written BEFORE the message is handed to that channel
//! (the sentinel's snapshot boundary depends on that order). The line
//! therefore CLAIMS the message went to `relay_url`, and four downstream
//! oracles inherit the claim. Teardown must not falsify it, so:
//!
//! * when a connection ends, the writers are DRAINED under a bound
//!   ([`TEARDOWN_DRAIN`]) instead of being cancelled, and
//! * if the bound expires — or a socket died with frames still queued — the
//!   count of journalled frames that did NOT go out is recorded, per
//!   direction, as a `conn_error` line.
//!
//! Both halves are needed. A drain alone still loses frames when the far end
//! stops reading, and silently dropping there would reinstate exactly the same
//! false claim in a rarer, harder-to-notice case.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use crate::frame::{classify_binary, classify_text, sentinel_ack, Observation};
use crate::journal::{now_ms, Dir, Endpoint, WireJournal};

/// How long a connection's teardown waits for frames the journal has already
/// recorded to reach their socket.
///
/// Generous for the loopback relays these lanes run, and bounded so a peer
/// that has stopped reading cannot pin a connection task open forever. When it
/// expires the shortfall is recorded rather than dropped.
const TEARDOWN_DRAIN: Duration = Duration::from_secs(5);

/// `reason` recorded when journalled client→relay frames never left the proxy.
const REASON_C2R_DISCARDED: &str = "c2r frames discarded";
/// `reason` recorded when journalled relay→client frames never left the proxy.
const REASON_R2C_DISCARDED: &str = "r2c frames discarded";
/// `reason` recorded when the client→relay stream failed mid-connection.
const REASON_C2R_READ_FAILED: &str = "c2r read failed";
/// `reason` recorded when the relay→client stream failed mid-connection.
const REASON_R2C_READ_FAILED: &str = "r2c read failed";

/// One `listen -> upstream` mapping.
#[derive(Debug, Clone)]
pub struct Route {
    /// Address to bind. Loopback only in every supported lane.
    pub listen: SocketAddr,
    /// Upstream relay URL, e.g. `ws://127.0.0.1:7777`.
    pub upstream: String,
}

/// The proxy's full routing table.
#[derive(Debug, Clone, Default)]
pub struct ProxyConfig {
    /// Routes to serve. Must be non-empty.
    pub routes: Vec<Route>,
}

/// A running proxy.
pub struct Proxy {
    bound: Vec<Route>,
    journal: Arc<WireJournal>,
    connections: Arc<AtomicU64>,
    accept_tasks: Vec<JoinHandle<()>>,
}

impl Proxy {
    /// Binds every route's listener and starts accepting.
    ///
    /// Binding is the one thing that is NOT fail-open: a proxy that cannot
    /// listen leaves the app pointed at a dead port, so the lane must fail
    /// loudly at startup rather than silently run without a relay.
    ///
    /// # Errors
    ///
    /// Returns the underlying [`std::io::Error`] when a listener cannot bind,
    /// or an `InvalidInput` error when the routing table is empty.
    pub async fn start(config: &ProxyConfig, journal: Arc<WireJournal>) -> std::io::Result<Self> {
        if config.routes.is_empty() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "at least one route is required",
            ));
        }

        let connections = Arc::new(AtomicU64::new(0));
        let mut bound = Vec::with_capacity(config.routes.len());
        let mut accept_tasks = Vec::with_capacity(config.routes.len());

        for route in &config.routes {
            let listener = TcpListener::bind(route.listen).await?;
            let local_addr = listener.local_addr()?;
            bound.push(Route {
                listen: local_addr,
                upstream: route.upstream.clone(),
            });

            let endpoint = Endpoint {
                upstream: route.upstream.clone(),
                listen: local_addr.to_string(),
            };
            let journal = Arc::clone(&journal);
            let connections = Arc::clone(&connections);
            accept_tasks.push(tokio::spawn(accept_loop(
                listener,
                endpoint,
                connections,
                journal,
            )));
        }

        Ok(Self {
            bound,
            journal,
            connections,
            accept_tasks,
        })
    }

    /// The routes actually bound (port-0 requests are resolved here).
    #[must_use]
    pub fn bound_routes(&self) -> &[Route] {
        &self.bound
    }

    /// Convenience for the single-route case.
    ///
    /// # Panics
    ///
    /// Never in practice: [`Proxy::start`] rejects an empty routing table, so
    /// at least one route is always bound.
    #[must_use]
    pub fn local_addr(&self) -> SocketAddr {
        self.bound
            .first()
            .map_or_else(|| SocketAddr::from(([0, 0, 0, 0], 0)), |r| r.listen)
    }

    /// Connections accepted so far, across every route.
    #[must_use]
    pub fn connection_count(&self) -> u64 {
        self.connections.load(Ordering::SeqCst)
    }

    /// The shared journal.
    #[must_use]
    pub const fn journal(&self) -> &Arc<WireJournal> {
        &self.journal
    }

    /// Stops accepting. In-flight connections end when their peers close.
    pub fn shutdown(&self) {
        for task in &self.accept_tasks {
            task.abort();
        }
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.shutdown();
    }
}

async fn accept_loop(
    listener: TcpListener,
    endpoint: Endpoint,
    connections: Arc<AtomicU64>,
    journal: Arc<WireJournal>,
) {
    loop {
        match listener.accept().await {
            Ok((stream, _peer)) => {
                let index = connections.fetch_add(1, Ordering::SeqCst);
                let conn_id = format!("c{index}");
                let journal = Arc::clone(&journal);
                let endpoint = endpoint.clone();
                tokio::spawn(async move {
                    handle_connection(stream, conn_id, endpoint, journal).await;
                });
            }
            Err(err) => {
                // A transient accept error must not kill the listener: every
                // still-open connection would be orphaned and the scenario
                // would fail on the proxy rather than on the app.
                eprintln!(
                    "[haven-wire-proxy] accept failed ({:?}); continuing",
                    err.kind()
                );
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        }
    }
}

/// Pumps one client connection to the relay and back, recording as it goes.
async fn handle_connection(
    stream: TcpStream,
    conn_id: String,
    endpoint: Endpoint,
    journal: Arc<WireJournal>,
) {
    // Nagle off: `ts_ms` should reflect when a message was observed, not when
    // a coalescing timer expired.
    let _ = stream.set_nodelay(true);

    // Emitted BEFORE the handshakes, so a connection that never completes one
    // still binds its conn_id to an endpoint. "The app dialled this relay and
    // sent nothing" is a containment finding, not an absence of data.
    journal.record_conn_open(&conn_id, &endpoint, now_ms());

    let downstream = match tokio_tungstenite::accept_async(stream).await {
        Ok(ws) => ws,
        Err(err) => {
            let label = ws_error_label(&err);
            eprintln!("[haven-wire-proxy] {conn_id}: client handshake failed ({label})");
            journal.record_conn_error(&conn_id, &endpoint, now_ms(), "client handshake failed");
            return;
        }
    };

    let upstream_ws = match tokio_tungstenite::connect_async(endpoint.upstream.as_str()).await {
        Ok((ws, _response)) => ws,
        Err(err) => {
            let label = ws_error_label(&err);
            eprintln!(
                "[haven-wire-proxy] {conn_id}: upstream connect failed ({label}); \
                 closing client connection"
            );
            journal.record_conn_error(&conn_id, &endpoint, now_ms(), "upstream connect failed");
            return;
        }
    };

    let (to_client, from_client) = downstream.split();
    let (to_relay, from_relay) = upstream_ws.split();

    // Both the relay pump and the sentinel responder write to the client, so
    // the client sink is owned by ONE task fed over a channel. Two tasks
    // sharing a split sink would need a mutex and could interleave a write.
    let (client_tx, client_rx) = mpsc::unbounded_channel::<Outbound>();
    let (relay_tx, relay_rx) = mpsc::unbounded_channel::<Outbound>();

    // Per-direction ledgers. `claimed` counts the frames the journal has said
    // went out; `delivered` counts the ones that actually reached a socket.
    // Their difference is the exact number of journal lines whose claim would
    // be false — and it stays readable even if a writer has to be cancelled,
    // which is why it is a pair of counters rather than a return value.
    let c2r_ledger = Ledger::default();
    let r2c_ledger = Ledger::default();

    // `mut` because the teardown below awaits each handle THROUGH a borrow, so
    // a writer that finished within the bound is never polled again.
    let mut client_writer = tokio::spawn(writer(to_client, client_rx, r2c_ledger.delivered()));
    let mut relay_writer = tokio::spawn(writer(to_relay, relay_rx, c2r_ledger.delivered()));

    let c2r = pump(
        from_client,
        relay_tx,
        Some(client_tx.clone()),
        Dir::ClientToRelay,
        &conn_id,
        &endpoint,
        &journal,
        c2r_ledger.claimed(),
    );
    let r2c = pump(
        from_relay,
        client_tx,
        None,
        Dir::RelayToClient,
        &conn_id,
        &endpoint,
        &journal,
        r2c_ledger.claimed(),
    );

    // Either direction ending tears the pair down: a half-open proxy would
    // leave the app waiting on a socket that can never answer.
    tokio::select! {
        () = c2r => {}
        () = r2c => {}
    }

    // Both pump futures are dropped here, which drops every sender, which is
    // what lets each writer finish its queue and exit on its own. Cancelling
    // them instead would destroy messages the journal has ALREADY recorded as
    // sent — the instrument perturbing the scenario it observes, and lying
    // about it.
    //
    // ONE deadline shared by both, awaited concurrently: a writer whose peer
    // has stopped reading must not eat the other writer's budget. Each handle
    // is borrowed rather than consumed, so the ones that finished are never
    // touched again and only the ones that did not are cancelled.
    let deadline = tokio::time::Instant::now() + TEARDOWN_DRAIN;
    let (client_drained, relay_drained) = tokio::join!(
        tokio::time::timeout_at(deadline, &mut client_writer),
        tokio::time::timeout_at(deadline, &mut relay_writer),
    );
    // The bound is not a licence to drop silently: stop whatever is still
    // stuck, then let the ledgers below say exactly how much was lost.
    if client_drained.is_err() {
        stop(client_writer).await;
    }
    if relay_drained.is_err() {
        stop(relay_writer).await;
    }

    record_shortfall(
        &journal,
        &conn_id,
        &endpoint,
        REASON_C2R_DISCARDED,
        &c2r_ledger,
    );
    record_shortfall(
        &journal,
        &conn_id,
        &endpoint,
        REASON_R2C_DISCARDED,
        &r2c_ledger,
    );
}

/// One direction's delivery ledger.
///
/// `claimed` is incremented by the pump the moment a journal line asserts the
/// message left for `relay_url`; `delivered` by the writer once the message is
/// actually in the socket. `claimed - delivered` is therefore the number of
/// journal lines that would be overstating what happened.
#[derive(Debug, Default)]
struct Ledger {
    claimed: Arc<AtomicU64>,
    delivered: Arc<AtomicU64>,
}

impl Ledger {
    fn claimed(&self) -> Arc<AtomicU64> {
        Arc::clone(&self.claimed)
    }

    fn delivered(&self) -> Arc<AtomicU64> {
        Arc::clone(&self.delivered)
    }

    /// Journalled frames that never reached a socket.
    fn shortfall(&self) -> u64 {
        self.claimed
            .load(Ordering::SeqCst)
            .saturating_sub(self.delivered.load(Ordering::SeqCst))
    }
}

/// A message queued for one of the two writer tasks.
struct Outbound {
    message: Message,
    /// `true` when a journal line has already CLAIMED this message was sent.
    ///
    /// Control frames and the synthesized sentinel ack are never journalled,
    /// so losing one is untidy but not a fidelity failure — counting them
    /// would inflate every discard record and make the honest ones ignorable.
    journalled: bool,
}

/// Owns one socket's write half and reports what it managed to deliver.
///
/// On a write failure it closes the RECEIVER rather than returning: that stops
/// the pump from recording further sends into a dead socket (the pump's next
/// `send` fails) while still letting this task drain — and therefore count —
/// everything already queued behind the failure.
async fn writer<S>(
    mut sink: S,
    mut rx: mpsc::UnboundedReceiver<Outbound>,
    delivered: Arc<AtomicU64>,
) where
    S: SinkExt<Message> + Unpin,
{
    let mut broken = false;
    while let Some(out) = rx.recv().await {
        if broken {
            continue;
        }
        if sink.send(out.message).await.is_err() {
            broken = true;
            rx.close();
        } else if out.journalled {
            delivered.fetch_add(1, Ordering::SeqCst);
        }
    }
    if !broken {
        let _ = sink.close().await;
    }
}

/// Cancels a writer and waits for the cancellation to land.
///
/// Awaiting matters: the ledger is read straight afterwards, and a task that
/// has been told to stop but not yet stopped could still be about to record a
/// delivery.
async fn stop(handle: JoinHandle<()>) {
    handle.abort();
    let _ = handle.await;
}

/// Records, per direction, how many journalled frames never left the proxy.
///
/// Emitted as a `conn_error` — the journal's existing lifecycle record for "a
/// connection did not complete end to end" — because the three record types
/// are a closed set that consumers validate against, and a fourth would make
/// every one of them report the journal UNUSABLE.
fn record_shortfall(
    journal: &WireJournal,
    conn_id: &str,
    endpoint: &Endpoint,
    reason: &'static str,
    ledger: &Ledger,
) {
    let missing = ledger.shortfall();
    if missing > 0 {
        eprintln!("[haven-wire-proxy] {conn_id}: {reason} ({missing})");
        journal.record_discarded(conn_id, endpoint, now_ms(), reason, missing);
    }
}

/// One direction of one connection.
///
/// `sentinel_reply` is `Some` only on the client→relay pump: a sentinel is a
/// client-originated marker and the ack goes back to that same client.
///
/// `claimed` counts the frames this pump has journalled AND handed to the
/// writer, i.e. the lines whose truth the teardown has to preserve.
#[allow(clippy::too_many_arguments)]
async fn pump<S>(
    mut source: S,
    forward: mpsc::UnboundedSender<Outbound>,
    sentinel_reply: Option<mpsc::UnboundedSender<Outbound>>,
    dir: Dir,
    conn_id: &str,
    endpoint: &Endpoint,
    journal: &WireJournal,
    claimed: Arc<AtomicU64>,
) where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    while let Some(next) = source.next().await {
        let message = match next {
            Ok(message) => message,
            Err(err) => {
                // A mid-stream transport failure — invalid UTF-8 in a text
                // frame, a protocol violation, a capacity overrun, a reset
                // without a closing handshake — is a FINDING, and precisely
                // the input this instrument exists to surface. Logging it only
                // on stderr left the journal ending in a lone `conn_open`,
                // indistinguishable from a clean close.
                let label = ws_error_label(&err);
                let direction = dir.as_str();
                eprintln!("[haven-wire-proxy] {conn_id} {direction}: read failed ({label})");
                journal.record_conn_error(conn_id, endpoint, now_ms(), read_failed_reason(dir));
                break;
            }
        };

        // A Close is FORWARDED before tearing this direction down, so the far
        // end still gets a proper closing handshake and neither peer reports a
        // reset. The proxy is meant to be invisible; a socket that always dies
        // dirty is not invisible. (The teardown DRAINS the writers for the
        // same reason: cancelling them destroyed this Close before it was ever
        // written, so every proxied connection died dirty.)
        if matches!(message, Message::Close(_)) {
            let _ = forward.send(Outbound {
                message,
                journalled: false,
            });
            break;
        }

        let observation: Option<Observation> = match &message {
            Message::Text(text) => Some(classify_text(text.as_str())),
            Message::Binary(bytes) => Some(classify_binary(bytes)),
            // Control frames are forwarded but never journalled — see the
            // module docs.
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) | Message::Close(_) => None,
        };

        let mut journalled = false;
        if let Some(observation) = observation {
            let seq = journal.record(conn_id, endpoint, dir, now_ms(), &observation);

            if let (Some(token), Some(reply)) = (&observation.sentinel, sentinel_reply.as_ref()) {
                // Intercepted, NOT forwarded: no relay ever sees the marker,
                // so no relay's unknown-command handling can perturb the
                // scenario, and the marker never appears in real relay traffic.
                // The ack is synthesized here, so it is not a journalled frame.
                let ack = sentinel_ack(token, seq, conn_id);
                let _ = reply.send(Outbound {
                    message: Message::Text(ack.into()),
                    journalled: false,
                });
                continue;
            }
            // Counted BEFORE the hand-off, not after: the journal line already
            // exists, so the claim exists. If the writer is gone and the send
            // below fails, this frame must still show up in the shortfall —
            // counting only successful hand-offs would hide exactly that case.
            journalled = true;
            claimed.fetch_add(1, Ordering::SeqCst);
        }

        if forward
            .send(Outbound {
                message,
                journalled,
            })
            .is_err()
        {
            break;
        }
    }
}

/// The fixed `conn_error` reason for a mid-stream read failure.
///
/// Direction, not error class: a `reason` is only useful to a consumer if its
/// vocabulary stays small and enumerable, and WHICH PEER emitted the bad frame
/// is the part that changes a verdict. The class is on stderr, which
/// `stop-wire-proxy.sh` tails into the lane log.
const fn read_failed_reason(dir: Dir) -> &'static str {
    match dir {
        Dir::ClientToRelay => REASON_C2R_READ_FAILED,
        Dir::RelayToClient => REASON_R2C_READ_FAILED,
    }
}

/// A fixed label per transport-error class.
///
/// Never the error's own message: tungstenite surfaces relay-authored text
/// (an HTTP response body, a close reason), and interpolating it would let a
/// remote peer write into this process's logs.
const fn ws_error_label(err: &tokio_tungstenite::tungstenite::Error) -> &'static str {
    use tokio_tungstenite::tungstenite::Error as E;
    match err {
        E::ConnectionClosed => "connection closed",
        E::AlreadyClosed => "already closed",
        E::Io(_) => "io",
        E::Tls(_) => "tls",
        E::Capacity(_) => "capacity",
        E::Protocol(_) => "protocol",
        E::WriteBufferFull(_) => "write buffer full",
        E::Utf8 => "invalid utf-8",
        E::AttackAttempt => "attack attempt",
        E::Url(_) => "bad url",
        E::Http(_) => "http",
        E::HttpFormat(_) => "http format",
    }
}
