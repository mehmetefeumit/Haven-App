//! MEASUREMENT tests for connection teardown.
//!
//! # Why these are counts and not assertions about code paths
//!
//! The journal's whole value rests on one claim: a line recorded with
//! `dir:"c2r"` and a `relay_url` means those bytes went to that relay. Four
//! downstream oracles inherit it. A test that merely exercises teardown proves
//! nothing about that claim — the proxy's existing suite was fully green while
//! ~96% of the last publish on every connection was being destroyed after
//! having been journalled as sent.
//!
//! So every test here MEASURES: it counts what the journal claims and counts
//! what the far end actually received, and asserts the two numbers agree. The
//! upstream in these tests is a counting server rather than a relay precisely
//! so "did this arrive?" is answerable.

use std::io::{self, Write};
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use haven_local_relay::journal::{WireJournal, TYPE_FRAME};
use haven_local_relay::proxy::{Proxy, ProxyConfig, Route};
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// What actually reached the far end.
#[derive(Debug, Default)]
struct Arrived {
    /// Text messages received.
    text: AtomicUsize,
    /// WebSocket Close frames received.
    closes: AtomicUsize,
}

impl Arrived {
    fn text(&self) -> usize {
        self.text.load(Ordering::SeqCst)
    }

    fn closes(&self) -> usize {
        self.closes.load(Ordering::SeqCst)
    }
}

/// What an upstream connection does once its handshake completes.
#[derive(Clone, Copy)]
enum Upstream {
    /// Count, and answer every text message with `["ECHO",<text>]`.
    Echo,
    /// Send `n` text messages and then a Close, immediately on connect.
    BurstThenClose(usize),
    /// Count only; answer nothing. The client-side pipelining case.
    Count,
}

/// How long the upstream waits before completing its WebSocket handshake.
///
/// Zero for most cases. A non-zero value models a relay that is not
/// loopback-instant — which is every real relay — and is what puts a client's
/// whole batch in the proxy's socket buffer BEFORE either pump has run.
type HandshakeDelay = Duration;

/// A counting upstream. Returns its URL and the arrival counters.
async fn start_upstream(behaviour: Upstream) -> (String, Arc<Arrived>) {
    start_slow_upstream(behaviour, Duration::ZERO).await
}

async fn start_slow_upstream(behaviour: Upstream, delay: HandshakeDelay) -> (String, Arc<Arrived>) {
    let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("upstream binds");
    let addr = listener.local_addr().expect("upstream addr");
    let arrived = Arc::new(Arrived::default());
    let counters = Arc::clone(&arrived);

    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let counters = Arc::clone(&counters);
            tokio::spawn(async move {
                if !delay.is_zero() {
                    tokio::time::sleep(delay).await;
                }
                let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else {
                    return;
                };
                if let Upstream::BurstThenClose(n) = behaviour {
                    for i in 0..n {
                        let line = format!(r#"["EVENT","s",{{"kind":445,"seq":{i}}}]"#);
                        if ws.send(Message::Text(line.into())).await.is_err() {
                            return;
                        }
                    }
                    let _ = ws.close(None).await;
                }
                while let Some(next) = ws.next().await {
                    match next {
                        Ok(Message::Text(text)) => {
                            counters.text.fetch_add(1, Ordering::SeqCst);
                            if matches!(behaviour, Upstream::Echo) {
                                let echo = Value::Array(vec![
                                    Value::String("ECHO".to_owned()),
                                    Value::String(text.as_str().to_owned()),
                                ])
                                .to_string();
                                if ws.send(Message::Text(echo.into())).await.is_err() {
                                    return;
                                }
                            }
                        }
                        Ok(Message::Close(_)) => {
                            counters.closes.fetch_add(1, Ordering::SeqCst);
                            return;
                        }
                        Ok(_) => {}
                        Err(_) => return,
                    }
                }
            });
        }
    });

    (format!("ws://{addr}"), arrived)
}

/// A capturing, in-memory journal sink.
#[derive(Clone, Default)]
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Capture {
    fn lines(&self) -> Vec<Value> {
        let guard = self.0.lock().expect("capture lock");
        String::from_utf8_lossy(&guard)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).expect("every journal line is JSON"))
            .collect()
    }

    /// How many traffic lines the journal CLAIMS were carried in `dir`.
    fn claimed(&self, dir: &str) -> usize {
        self.lines()
            .iter()
            .filter(|l| l["type"] == TYPE_FRAME && l["dir"] == dir)
            .count()
    }

    /// Every `conn_error` reason the journal recorded, in order.
    fn conn_error_reasons(&self) -> Vec<String> {
        self.lines()
            .iter()
            .filter(|l| l["type"] == "conn_error")
            .filter_map(|l| l["reason"].as_str().map(str::to_owned))
            .collect()
    }

    /// Frames the journal admits it claimed but could not deliver.
    fn discarded(&self) -> u64 {
        self.lines()
            .iter()
            .filter_map(|l| l["discarded"].as_u64())
            .sum()
    }
}

impl Write for Capture {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        {
            let mut guard = self.0.lock().expect("capture lock");
            guard.extend_from_slice(buf);
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

async fn start_proxy(upstream: String, journal: Arc<WireJournal>) -> Proxy {
    Proxy::start(
        &ProxyConfig {
            routes: vec![Route {
                listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                upstream,
            }],
        },
        journal,
    )
    .await
    .expect("proxy binds")
}

async fn connect(addr: SocketAddr) -> Client {
    let (client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}").as_str())
        .await
        .expect("client connects through the proxy");
    client
}

/// Sends the closing handshake and then reads to the end of the stream.
///
/// Draining afterwards is what keeps the measurement from flaking: dropping a
/// socket that still has unread bytes queued makes the kernel emit an RST,
/// which can discard the Close we just wrote. It does NOT weaken the
/// measurement — whatever the proxy destroys, it destroys the moment its first
/// pump ends, long before the client stops reading.
async fn close_and_drain(mut client: Client) {
    let _ = client.close(None).await;
    let _ = tokio::time::timeout(Duration::from_secs(10), async {
        while client.next().await.is_some() {}
    })
    .await;
}

/// Polls `probe` until it reaches `want`, then returns whatever it last saw.
///
/// Returning rather than asserting is deliberate: the caller compares the two
/// COUNTS in its own assertion message, so a failure reports "journal claimed
/// 200, upstream received 104" instead of "condition was false".
async fn settle(want: usize, probe: impl Fn() -> usize) -> usize {
    for _ in 0..200 {
        let seen = probe();
        if seen >= want {
            return seen;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    probe()
}

// ---------------------------------------------------------------------------
// Measurements
// ---------------------------------------------------------------------------

const WARM: &str = r#"["REQ","warm",{"kinds":[445]}]"#;
const PUBLISH: &str = r#"["EVENT",{"kind":445,"content":"final-publish"}]"#;

/// THE measurement. A warm round-trip, one publish, then close — the exact
/// shape of an app's last act on a connection — repeated until an occasional
/// loss would be unmistakable.
///
/// Both numbers are counted: how many `c2r` lines the journal claims left for
/// `relay_url`, and how many text messages the upstream actually received. A
/// journal that overstates the second is worse than no journal, because every
/// oracle downstream reasons about what left the device using the first.
#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn every_c2r_frame_the_journal_claims_reaches_the_upstream() {
    const ROUNDS: usize = 100;
    const PER_ROUND: usize = 2; // the warm REQ and the publish

    let (upstream, arrived) = start_upstream(Upstream::Echo).await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(upstream, Arc::clone(&journal)).await;
    let addr = proxy.local_addr();

    for _ in 0..ROUNDS {
        let mut client = connect(addr).await;
        client
            .send(Message::Text(WARM.into()))
            .await
            .expect("warm send");
        // Wait for the echo: the pipe is now proven warm end to end, so a
        // later loss cannot be blamed on a connection that never worked.
        let warmed = tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(Ok(message)) = client.next().await {
                if matches!(&message, Message::Text(t) if t.as_str().contains("ECHO")) {
                    return true;
                }
            }
            false
        })
        .await
        .expect("warm echo did not arrive in time");
        assert!(warmed, "the upstream never echoed the warm-up message");

        // `feed` + `close`, NOT `send` + `close`: a client that publishes and
        // immediately closes flushes both frames in one write, so the proxy
        // reads them from one buffer fill and its c2r pump never yields
        // between them. That is the realistic shape of an app's last act on a
        // connection, and it is the shape under which the queued publish is
        // destroyed.
        client
            .feed(Message::Text(PUBLISH.into()))
            .await
            .expect("publish feed");
        close_and_drain(client).await;
    }

    let expected = ROUNDS * PER_ROUND;
    let received = settle(expected, || arrived.text()).await;
    let claimed = settle(expected, || capture.claimed("c2r")).await;

    assert_eq!(
        claimed, expected,
        "precondition: the journal must have recorded every c2r frame \
         (claimed {claimed}, expected {expected})"
    );
    assert_eq!(
        received,
        claimed,
        "the journal CLAIMS {claimed} c2r frames reached the upstream but only \
         {received} arrived — {} frame(s) were journalled as sent and then \
         destroyed at teardown. Every oracle that reasons about what left the \
         device inherits that overstatement.",
        claimed - received
    );

    // The proxy documents that a Close is FORWARDED before teardown, so neither
    // peer reports a reset. That claim is measurable too, and it was false.
    let closes = settle(ROUNDS, || arrived.closes()).await;
    assert_eq!(
        closes, ROUNDS,
        "only {closes} of {ROUNDS} Close frames reached the upstream; the \
         closing handshake the proxy promises is not happening"
    );

    // Nothing was lost, so the journal must not be claiming otherwise either.
    assert_eq!(
        capture.discarded(),
        0,
        "no frame was actually lost, so no discard record should exist"
    );
}

/// The mirror image: a relay that bursts and then closes. The journal records
/// every `r2c` frame; the client must receive every one of them.
///
/// This is the direction an oracle uses to decide what the app was ABLE to
/// see, and losing it silently would make "the app never received X" and "the
/// proxy destroyed X" indistinguishable.
#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn every_r2c_frame_the_journal_claims_reaches_the_client() {
    const ROUNDS: usize = 50;
    const BURST: usize = 5;

    let (upstream, _arrived) = start_upstream(Upstream::BurstThenClose(BURST)).await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(upstream, Arc::clone(&journal)).await;
    let addr = proxy.local_addr();

    let mut delivered = 0usize;
    for _ in 0..ROUNDS {
        let mut client = connect(addr).await;
        let seen = tokio::time::timeout(Duration::from_secs(10), async {
            let mut seen = 0usize;
            while let Some(next) = client.next().await {
                match next {
                    Ok(Message::Text(_)) => seen += 1,
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            seen
        })
        .await
        .expect("the client stream never ended");
        delivered += seen;
    }

    let expected = ROUNDS * BURST;
    let claimed = settle(expected, || capture.claimed("r2c")).await;

    assert_eq!(
        claimed, expected,
        "precondition: the journal must have recorded every r2c frame \
         (claimed {claimed}, expected {expected})"
    );
    assert_eq!(
        delivered, claimed,
        "the journal CLAIMS {claimed} r2c frames were carried to the client but \
         only {delivered} arrived — a burst that ends in a Close is destroyed \
         at teardown"
    );
    assert_eq!(
        capture.discarded(),
        0,
        "nothing was lost; claim nothing lost"
    );
}

/// The hardest case: everything the peer sends, including its Close, is
/// already buffered when the pump first runs. The pump then drains the whole
/// batch without yielding, so a teardown that cancels its writers cancels them
/// before they have ever been polled — and destroys the entire connection's
/// traffic, not merely its tail.
///
/// The upstream's handshake is deliberately slow, which is what makes this
/// deterministic rather than a race: the proxy is still inside `connect_async`
/// while the client writes its whole batch, so the batch is guaranteed to be
/// waiting when the pumps start. A loopback relay that answers instantly hides
/// the defect behind scheduling luck; a real relay does not.
#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn a_pipelined_batch_closed_immediately_still_reaches_the_upstream() {
    const ROUNDS: usize = 50;
    const PER_ROUND: usize = 3;

    let (upstream, arrived) =
        start_slow_upstream(Upstream::Count, Duration::from_millis(150)).await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(upstream, Arc::clone(&journal)).await;
    let addr = proxy.local_addr();

    for round in 0..ROUNDS {
        let mut client = connect(addr).await;
        for i in 0..PER_ROUND {
            let line = format!(r#"["EVENT",{{"kind":445,"round":{round},"i":{i}}}]"#);
            client
                .feed(Message::Text(line.into()))
                .await
                .expect("pipelined feed");
        }
        client.flush().await.expect("pipelined flush");
        close_and_drain(client).await;
    }

    let expected = ROUNDS * PER_ROUND;
    let received = settle(expected, || arrived.text()).await;
    let claimed = settle(expected, || capture.claimed("c2r")).await;

    assert_eq!(
        claimed, expected,
        "precondition: the journal must have recorded every pipelined frame \
         (claimed {claimed}, expected {expected})"
    );
    assert_eq!(
        received, claimed,
        "the journal CLAIMS {claimed} pipelined c2r frames reached the upstream \
         but only {received} arrived"
    );
}

/// When the drain genuinely cannot finish, the journal must SAY so rather than
/// leave its earlier lines standing as unqualified claims.
///
/// The fixture is an upstream that completes the WebSocket handshake and then
/// never reads again, so the proxy's write to it blocks on a full socket
/// buffer until the teardown bound expires. A silent drop here would be the
/// same lie as an unbounded abort, only rarer and therefore harder to catch.
#[tokio::test(flavor = "multi_thread")]
async fn a_drain_that_cannot_finish_records_the_discard_instead_of_hiding_it() {
    // Big enough that no socket buffer swallows the whole batch.
    const PAYLOAD: usize = 512 * 1024;
    const BATCH: usize = 24;

    let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("upstream binds");
    let addr = listener.local_addr().expect("upstream addr");
    let stalled = tokio::spawn(async move {
        // Accept, handshake, then never read a byte. The accepted stream is
        // parked in a future that is never polled again, which keeps the
        // connection open while nothing drains the socket.
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                    std::future::pending::<()>().await;
                    drop(ws);
                }
            });
        }
    });

    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(format!("ws://{addr}"), Arc::clone(&journal)).await;

    let mut client = connect(proxy.local_addr()).await;
    let filler = "x".repeat(PAYLOAD);
    for i in 0..BATCH {
        let line = format!(r#"["EVENT",{{"kind":445,"i":{i},"content":"{filler}"}}]"#);
        client
            .feed(Message::Text(line.into()))
            .await
            .expect("feed into the stalled upstream");
    }
    client.flush().await.expect("flush");
    close_and_drain(client).await;

    // The teardown bound has to expire before the discard is knowable.
    let discarded = settle(1, || {
        usize::try_from(capture.discarded()).unwrap_or(usize::MAX)
    })
    .await;

    let claimed = capture.claimed("c2r");
    assert_eq!(
        claimed, BATCH,
        "precondition: every frame must have been journalled (claimed {claimed})"
    );
    assert!(
        discarded > 0,
        "the drain could not finish, so some of the {claimed} journalled c2r \
         frames never left the proxy — the journal must record that discard \
         rather than let the earlier lines stand as unqualified claims"
    );
    let reasons = capture.conn_error_reasons();
    assert!(
        reasons.iter().any(|r| r == "c2r frames discarded"),
        "the discard must be recorded under a fixed, direction-bearing label so \
         a consumer can find it; saw {reasons:?}"
    );

    stalled.abort();
}
