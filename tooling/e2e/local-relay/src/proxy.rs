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
//! # The device→host control channel
//!
//! Two verbs a CLIENT may send are intercepted here and never reach a relay:
//! `HAVEN_WIRE_SENTINEL` (a snapshot marker, journalled as ordinary `c2r`
//! traffic) and `HAVEN_WIRE_MLS_GROUP_ID` (the real MLS group id, journalled
//! NOWHERE — it goes to [`MlsGroupIdSink`]). Both are answered with a
//! synthesized ack, and neither ack is journalled: recording one as `r2c`
//! would claim the relay sent it.
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

use std::collections::BTreeSet;
use std::fs::OpenOptions;
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use crate::frame::{
    classify_binary, classify_text, mls_group_id_ack, sentinel_ack, validate_mls_group_id,
    MlsGroupIdRejection, Observation, MLS_GROUP_ID_VERB,
};
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
    mls_group_ids: Arc<MlsGroupIdSink>,
    connections: Arc<AtomicU64>,
    accept_tasks: Vec<JoinHandle<()>>,
}

impl Proxy {
    /// Binds every route's listener and starts accepting.
    ///
    /// `mls_group_ids` receives the real MLS group ids the device declares over
    /// the control channel. It is a SEPARATE sink from the journal on purpose —
    /// see [`MlsGroupIdSink`].
    ///
    /// Binding is the one thing that is NOT fail-open: a proxy that cannot
    /// listen leaves the app pointed at a dead port, so the lane must fail
    /// loudly at startup rather than silently run without a relay.
    ///
    /// # Errors
    ///
    /// Returns the underlying [`std::io::Error`] when a listener cannot bind,
    /// or an `InvalidInput` error when the routing table is empty.
    pub async fn start(
        config: &ProxyConfig,
        journal: Arc<WireJournal>,
        mls_group_ids: Arc<MlsGroupIdSink>,
    ) -> std::io::Result<Self> {
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
            let mls_group_ids = Arc::clone(&mls_group_ids);
            let connections = Arc::clone(&connections);
            accept_tasks.push(tokio::spawn(accept_loop(
                listener,
                endpoint,
                connections,
                journal,
                mls_group_ids,
            )));
        }

        Ok(Self {
            bound,
            journal,
            mls_group_ids,
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

    /// The sidecar the declared MLS group ids go to.
    #[must_use]
    pub const fn mls_group_ids(&self) -> &Arc<MlsGroupIdSink> {
        &self.mls_group_ids
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

// ---------------------------------------------------------------------------
// The MLS-group-id sidecar
// ---------------------------------------------------------------------------

/// What the proxy did with one declared MLS group id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Declared {
    /// Validated, not seen before, appended to the sidecar.
    Recorded,
    /// Validated and already in the sidecar; nothing was written.
    Duplicate,
    /// Refused; nothing was written.
    Refused(MlsGroupIdRejection),
    /// Validated, but no sidecar path is configured, so it went nowhere.
    Unconfigured,
    /// Validated, but the sidecar could not be appended to.
    Unwritable(std::io::ErrorKind),
}

impl Declared {
    /// `true` when the value did NOT reach the sidecar and never will.
    const fn is_lost(self) -> bool {
        matches!(self, Self::Unconfigured | Self::Unwritable(_))
    }
}

/// The outcome of one declaration, plus what to answer the client with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declaration {
    /// What happened to the value.
    pub outcome: Declared,
    /// The normalized lowercase hex to ack with, present exactly when the
    /// value is in the sidecar. A refused or lost value is deliberately NOT
    /// acked: a harness that got an ack must be able to treat it as proof that
    /// the host will see the id, and a lane that silently lost its Rule-4
    /// ground truth would run C5.8 against an empty needle set and pass
    /// vacuously.
    pub ack: Option<String>,
}

/// Health of the sidecar, for the shutdown summary.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MlsGroupIdStats {
    /// Distinct ids written.
    pub distinct: usize,
    /// Declarations refused by the validator.
    pub refused: u64,
    /// Valid declarations that could not be recorded.
    pub lost: u64,
}

/// De-duplicating append-only sink for the REAL MLS group ids the device
/// declares.
///
/// # Why this is not the journal
///
/// The journal is the corpus C5.8 SCANS; this file is the needle it scans
/// FOR. Putting the id in the journal would make the oracle find the
/// announcement the harness itself made, and Security Rule 4 would read as
/// satisfied by an instrument talking to itself. The two must never be the
/// same file, and the proxy therefore intercepts the declaration before the
/// recorder ever sees it.
///
/// # Why it is not a log line either
///
/// The drive log is uploaded as a CI artifact with 14-day retention and is the
/// canary oracle's `--manifest` input. A Rule-4 value travels only through a
/// file the lane does not upload — a decision recorded in
/// `haven/integration_test/e2e/_lib/wire_canaries.dart`, and enforced for this
/// file by `scripts/ci/check_wire_proxy_test_only.sh` check 3.
///
/// # Fail-open
///
/// Like the journal, an unwritable sidecar never stops traffic: it counts the
/// loss, says so on stderr, and lets the fail-closed oracle downstream turn the
/// missing ground truth into a red.
pub struct MlsGroupIdSink {
    inner: Mutex<SidecarInner>,
}

struct SidecarInner {
    path: Option<PathBuf>,
    seen: BTreeSet<String>,
    refused: u64,
    lost: u64,
}

impl MlsGroupIdSink {
    /// A sink appending to `path`, one lowercase hex id per line.
    ///
    /// The file is opened per write rather than held open: writes are rare (a
    /// handful per scenario, one per circle) and not holding an fd means a
    /// rotation between runs cannot strand this process on an unlinked inode —
    /// the hazard the journal needs its whole claim protocol to avoid.
    #[must_use]
    pub const fn new(path: PathBuf) -> Self {
        Self::with_optional_path(Some(path))
    }

    /// A sink that records nothing, for callers with no host-side oracle.
    #[must_use]
    pub const fn disabled() -> Self {
        Self::with_optional_path(None)
    }

    const fn with_optional_path(path: Option<PathBuf>) -> Self {
        Self {
            inner: Mutex::new(SidecarInner {
                path,
                seen: BTreeSet::new(),
                refused: 0,
                lost: 0,
            }),
        }
    }

    /// Validates, de-duplicates and records one declared MLS group id.
    ///
    /// Reports every outcome on stderr — a refusal that went unmentioned would
    /// leave a lane asserting Rule 4 against a needle set it never got.
    pub fn declare(&self, conn_id: &str, raw: &str) -> Declaration {
        let declared_len = raw.chars().count();
        let normalized = match validate_mls_group_id(raw) {
            Ok(normalized) => normalized,
            Err(reason) => {
                let mut inner = self.lock();
                inner.refused = inner.refused.wrapping_add(1);
                let distinct = inner.seen.len();
                drop(inner);
                let outcome = Declared::Refused(reason);
                eprintln!(
                    "{}",
                    declaration_notice(conn_id, declared_len, outcome, distinct)
                );
                return Declaration { outcome, ack: None };
            }
        };

        let mut inner = self.lock();
        if inner.seen.contains(&normalized) {
            // Silent by design: a scenario re-declares the same circle on every
            // reconnect, and a line per repeat would bury the first sighting.
            return Declaration {
                outcome: Declared::Duplicate,
                ack: Some(normalized),
            };
        }

        let outcome = inner.path.clone().map_or(Declared::Unconfigured, |path| {
            append_line(&path, &normalized).map_or_else(
                |err| Declared::Unwritable(err.kind()),
                |()| Declared::Recorded,
            )
        });
        if outcome == Declared::Recorded {
            inner.seen.insert(normalized.clone());
        } else if outcome.is_lost() {
            // NOT remembered as seen: a retry must get another chance rather
            // than be waved through as a duplicate of something never written.
            inner.lost = inner.lost.wrapping_add(1);
        }
        let distinct = inner.seen.len();
        drop(inner);

        eprintln!(
            "{}",
            declaration_notice(conn_id, declared_len, outcome, distinct)
        );
        Declaration {
            ack: (outcome == Declared::Recorded).then_some(normalized),
            outcome,
        }
    }

    /// Current health snapshot.
    #[must_use]
    pub fn stats(&self) -> MlsGroupIdStats {
        let inner = self.lock();
        MlsGroupIdStats {
            distinct: inner.seen.len(),
            refused: inner.refused,
            lost: inner.lost,
        }
    }

    /// A poison-tolerant lock. A panic elsewhere must not turn this sink into a
    /// second way for the instrument to kill the traffic it observes.
    fn lock(&self) -> std::sync::MutexGuard<'_, SidecarInner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Default for MlsGroupIdSink {
    fn default() -> Self {
        Self::disabled()
    }
}

/// Appends one line, creating the file if needed.
fn append_line(path: &Path, line: &str) -> Result<(), std::io::Error> {
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.flush()
}

/// Builds the stderr line for one declaration.
///
/// SECURITY RULE 6: the id is key-adjacent material and is never interpolated
/// here. The line carries a length, a count and a fixed label — enough to
/// debug a refusal, and nothing a reader of the CI log could scan for.
fn declaration_notice(
    conn_id: &str,
    declared_len: usize,
    outcome: Declared,
    distinct: usize,
) -> String {
    match outcome {
        Declared::Recorded => format!(
            "[haven-wire-proxy] {conn_id}: MLS group id declared ({declared_len} chars); \
             {distinct} distinct id(s) in the sidecar."
        ),
        Declared::Duplicate => format!(
            "[haven-wire-proxy] {conn_id}: MLS group id already declared ({declared_len} chars); \
             {distinct} distinct id(s) in the sidecar."
        ),
        Declared::Refused(reason) => format!(
            "[haven-wire-proxy] {conn_id}: REFUSED an MLS group id declaration ({}, \
             {declared_len} chars). It was neither forwarded nor journalled, and the host has \
             no ground truth for it — an oracle asserting Security Rule 4 against it would \
             scan for nothing and pass vacuously.",
            reason.as_str()
        ),
        Declared::Unconfigured => format!(
            "[haven-wire-proxy] {conn_id}: an MLS group id was declared ({declared_len} chars) \
             but NO sidecar path is configured, so it went nowhere. Set \
             HAVEN_WIRE_MLS_GROUP_ID_FILE."
        ),
        Declared::Unwritable(kind) => format!(
            "[haven-wire-proxy] {conn_id}: could not append a declared MLS group id \
             ({declared_len} chars) to the sidecar ({kind:?}); the host will not see it."
        ),
    }
}

async fn accept_loop(
    listener: TcpListener,
    endpoint: Endpoint,
    connections: Arc<AtomicU64>,
    journal: Arc<WireJournal>,
    mls_group_ids: Arc<MlsGroupIdSink>,
) {
    loop {
        match listener.accept().await {
            Ok((stream, _peer)) => {
                let index = connections.fetch_add(1, Ordering::SeqCst);
                let conn_id = format!("c{index}");
                let journal = Arc::clone(&journal);
                let mls_group_ids = Arc::clone(&mls_group_ids);
                let endpoint = endpoint.clone();
                tokio::spawn(async move {
                    handle_connection(stream, conn_id, endpoint, journal, mls_group_ids).await;
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
    mls_group_ids: Arc<MlsGroupIdSink>,
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
        Some(Control {
            reply: client_tx.clone(),
            mls_group_ids: &mls_group_ids,
        }),
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

/// The client-facing half of a control exchange.
///
/// Held only by the client→relay pump, which is what makes "control verbs are
/// client-originated" a property of the types rather than of a convention: the
/// relay→client pump has no way to reach `reply` or the sidecar, so nothing a
/// RELAY sends can be intercepted, acked, or written to the host's ground
/// truth.
///
/// A relay that emits one of these verbs is therefore journalled and delivered
/// like any other unknown frame, which is the honest reading — it is observed
/// traffic, and dropping it would violate the recorder's "never drop a line"
/// rule for the sake of a case that carries no secret. It cannot carry a real
/// MLS group id either: the c2r side never forwards one, so no relay can have
/// learned a value to echo back.
struct Control<'a> {
    /// Sink for synthesized acks — the same channel the relay→client pump
    /// writes to, which is why the client socket is owned by one writer task.
    reply: mpsc::UnboundedSender<Outbound>,
    /// Where a declared MLS group id goes. NEVER the journal.
    mls_group_ids: &'a MlsGroupIdSink,
}

/// One direction of one connection.
///
/// `control` is `Some` only on the client→relay pump: both control verbs are
/// client-originated and both acks go back to that same client.
///
/// `claimed` counts the frames this pump has journalled AND handed to the
/// writer, i.e. the lines whose truth the teardown has to preserve.
#[allow(clippy::too_many_arguments)]
async fn pump<S>(
    mut source: S,
    forward: mpsc::UnboundedSender<Outbound>,
    control: Option<Control<'_>>,
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

        // BYTE-LEVEL GATE, ahead of classification. Interception used to be
        // keyed on `Observation.mls_group_id`, which is only ever set when the
        // payload parses as a JSON array whose first element is a string. Every
        // other shape — malformed JSON, a non-array, a Binary frame — fell
        // through to the ordinary path and was BOTH journalled (with the whole
        // id inside `raw_preview`, which keeps 200 chars against a ~95-char
        // declaration) AND forwarded to the relay. That made the Rule 4
        // guarantee a property of the PARSER rather than of the verb: today's
        // sender emits well-formed JSON, so it was unreachable, but it is the
        // one place an edit on either side could break the invariant silently.
        //
        // A frame naming the declaration verb is a declaration whatever else is
        // wrong with it, and is refused rather than relayed.
        if control.is_some() {
            let names_verb = match &message {
                Message::Text(text) => text.as_str().contains(MLS_GROUP_ID_VERB),
                Message::Binary(bytes) => bytes
                    .windows(MLS_GROUP_ID_VERB.len())
                    .any(|w| w == MLS_GROUP_ID_VERB.as_bytes()),
                _ => false,
            };
            let classified = matches!(&message, Message::Text(text)
                if classify_text(text.as_str()).mls_group_id.is_some());
            if names_verb && !classified {
                // Never journalled, never forwarded, never acked: an
                // unparseable declaration cannot be recorded, so acking it
                // would tell the drive the host holds a value it does not.
                eprintln!(
                    "[wire-proxy] conn={conn_id} refused an unparseable MLS-group-id declaration ({} bytes); not forwarded, not journalled",
                    match &message {
                        Message::Text(t) => t.as_str().len(),
                        Message::Binary(b) => b.len(),
                        _ => 0,
                    }
                );
                continue;
            }
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
            // INTERCEPTED BEFORE THE RECORDER — the one control frame that must
            // not reach the journal at all.
            //
            // The declared value is the REAL MLS group id, and the oracle that
            // consumes it (check-wire-correlation.sh C5.8) asserts Security
            // Rule 4 by scanning the journal for exactly that string. Record it
            // here and the scan finds the announcement the harness made itself:
            // the assertion would be an instrument talking to itself, and a
            // genuine leak would be indistinguishable from this line. It is not
            // forwarded either — Rule 4 says the id never reaches a relay, and
            // this interception is what guarantees it for this channel.
            //
            // Ordered before `record`, not after a `continue`, because the
            // journal has no retraction for a line it has already written.
            if let (Some(raw), Some(control)) = (&observation.mls_group_id, control.as_ref()) {
                let declaration = control.mls_group_ids.declare(conn_id, raw);
                if let Some(normalized) = declaration.ack {
                    let _ = control.reply.send(Outbound {
                        message: Message::Text(mls_group_id_ack(&normalized).into()),
                        journalled: false,
                    });
                }
                continue;
            }

            let seq = journal.record(conn_id, endpoint, dir, now_ms(), &observation);

            if let (Some(token), Some(control)) = (&observation.sentinel, control.as_ref()) {
                // Intercepted, NOT forwarded: no relay ever sees the marker,
                // so no relay's unknown-command handling can perturb the
                // scenario, and the marker never appears in real relay traffic.
                // The ack is synthesized here, so it is not a journalled frame.
                let ack = sentinel_ack(token, seq, conn_id);
                let _ = control.reply.send(Outbound {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A well-formed id: 32 bytes, the size MDK mints.
    fn an_id() -> String {
        "ab".repeat(32)
    }

    fn scratch(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        std::env::temp_dir().join(format!(
            "haven-wire-proxy-sidecar-{}-{tag}-{nanos}",
            std::process::id()
        ))
    }

    fn lines(path: &Path) -> Vec<String> {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn a_declared_id_lands_in_the_sidecar_and_is_acked() {
        let path = scratch("accept");
        let sink = MlsGroupIdSink::new(path.clone());

        let declaration = sink.declare("c0", &an_id());

        assert_eq!(declaration.outcome, Declared::Recorded);
        assert_eq!(declaration.ack.as_deref(), Some(an_id().as_str()));
        assert_eq!(lines(&path), vec![an_id()]);
        assert_eq!(sink.stats().distinct, 1);
        let _ = std::fs::remove_file(&path);
    }

    // A scenario has more than one circle, and every one of them has to reach
    // the oracle: C5.8 scans for the whole set, so a sink that kept only the
    // first would silently narrow the assertion to one group.
    #[test]
    fn several_distinct_ids_all_land_one_per_line() {
        let path = scratch("several");
        let sink = MlsGroupIdSink::new(path.clone());
        let first = an_id();
        let second = "cd".repeat(32);

        sink.declare("c0", &first);
        sink.declare("c1", &second);

        assert_eq!(lines(&path), vec![first, second]);
        assert_eq!(sink.stats().distinct, 2);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_repeated_declaration_is_deduplicated_but_still_acked() {
        let path = scratch("dedupe");
        let sink = MlsGroupIdSink::new(path.clone());

        sink.declare("c0", &an_id());
        // Same value, different case and a different connection — a reconnect
        // re-declaring what it already declared.
        let again = sink.declare("c1", &"AB".repeat(32));

        assert_eq!(again.outcome, Declared::Duplicate);
        assert_eq!(
            again.ack.as_deref(),
            Some(an_id().as_str()),
            "a duplicate must still be acked, or a reconnecting harness would hang"
        );
        assert_eq!(lines(&path), vec![an_id()], "no second line");
        let _ = std::fs::remove_file(&path);
    }

    // The refusal path is the one that decides whether a lane asserts Rule 4
    // or only appears to: a value the oracle would reject must be refused HERE
    // and said out loud, never written and never acked.
    #[test]
    fn a_malformed_or_short_id_is_refused_reported_and_never_written() {
        for (raw, want) in [
            ("zz".repeat(32), MlsGroupIdRejection::NotHex),
            (format!("{}a", an_id()), MlsGroupIdRejection::OddLength),
            ("ab".repeat(8), MlsGroupIdRejection::TooShort),
            ("ab".repeat(200), MlsGroupIdRejection::TooLong),
            (String::new(), MlsGroupIdRejection::NotHex),
        ] {
            let path = scratch("refuse");
            let sink = MlsGroupIdSink::new(path.clone());

            let declaration = sink.declare("c0", &raw);

            assert_eq!(
                declaration.outcome,
                Declared::Refused(want),
                "'{}' char value must be refused as {want:?}",
                raw.len()
            );
            assert!(
                declaration.ack.is_none(),
                "a refused value must not be acked"
            );
            assert!(
                !path.exists(),
                "a refused value must not create the sidecar at all"
            );
            let stats = sink.stats();
            assert_eq!(
                stats.refused, 1,
                "the refusal must be counted, not swallowed"
            );
            assert_eq!(stats.distinct, 0);
            let _ = std::fs::remove_file(&path);
        }
    }

    #[test]
    fn a_refusal_is_reported_with_its_reason_and_never_with_the_value() {
        let notice = declaration_notice(
            "c7",
            64,
            Declared::Refused(MlsGroupIdRejection::TooShort),
            0,
        );
        assert!(notice.contains("REFUSED"), "{notice}");
        assert!(
            notice.contains(MlsGroupIdRejection::TooShort.as_str()),
            "a refusal must name which rule it broke: {notice}"
        );
        assert!(notice.contains("64"), "the length is the debuggable part");
        assert!(notice.contains("c7"), "and which connection declared it");
    }

    // SECURITY RULE 6. Every line this sink emits must be safe to leave in a
    // CI log that outlives the runner, so none of them may carry the value.
    #[test]
    fn no_notice_ever_interpolates_the_id() {
        let id = an_id();
        for outcome in [
            Declared::Recorded,
            Declared::Duplicate,
            Declared::Refused(MlsGroupIdRejection::NotHex),
            Declared::Unconfigured,
            Declared::Unwritable(std::io::ErrorKind::PermissionDenied),
        ] {
            let notice = declaration_notice("c0", id.len(), outcome, 3);
            assert!(
                !notice.contains(&id),
                "{outcome:?} notice leaked the declared id: {notice}"
            );
        }
    }

    #[test]
    fn a_sink_with_no_path_loses_the_value_loudly_instead_of_acking_it() {
        let sink = MlsGroupIdSink::disabled();

        let declaration = sink.declare("c0", &an_id());

        assert_eq!(declaration.outcome, Declared::Unconfigured);
        assert!(
            declaration.ack.is_none(),
            "an ack must mean the host will see the id"
        );
        assert_eq!(sink.stats().lost, 1);
        assert_eq!(sink.stats().distinct, 0);
    }

    // An unwritable sidecar must not be remembered as "seen": a retry that got
    // waved through as a duplicate would ack a value that was never recorded.
    #[test]
    fn an_unwritable_sidecar_is_counted_and_leaves_the_value_retryable() {
        let dir = scratch("unwritable");
        // A path whose PARENT does not exist — an open that cannot succeed
        // without touching permissions or the filesystem's state.
        let path = dir.join("missing").join("ids.txt");
        let sink = MlsGroupIdSink::new(path);

        let first = sink.declare("c0", &an_id());
        let second = sink.declare("c0", &an_id());

        assert!(matches!(first.outcome, Declared::Unwritable(_)));
        assert!(
            matches!(second.outcome, Declared::Unwritable(_)),
            "a lost value must be retried, not reported as an already-recorded duplicate"
        );
        assert!(first.ack.is_none());
        assert_eq!(sink.stats().lost, 2);
        assert_eq!(sink.stats().distinct, 0);
    }
}
