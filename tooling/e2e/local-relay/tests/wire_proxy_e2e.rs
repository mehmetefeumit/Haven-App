//! Integration tests for the recording proxy: a REAL relay, a REAL proxy and
//! a REAL WebSocket client, asserting the journal that comes out.
//!
//! The unit tests in `src/` prove the pieces. These prove the assembly, and in
//! particular the two properties that only exist end to end:
//!
//! * every wire kind Haven publishes survives into the journal verbatim, and
//! * recording that dies MID-RUN (the realistic disk-full case, as opposed to
//!   a journal that never opened) does not stop traffic.

use std::io::{self, Write};
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use haven_local_relay::frame::{SENTINEL_ACK_VERB, SENTINEL_VERB};
use haven_local_relay::journal::{Degraded, WireJournal, TYPE_FRAME};
use haven_local_relay::loopback::RefusedAddr;
use haven_local_relay::proxy::{MlsGroupIdSink, Proxy, ProxyConfig, Route};
use nostr_relay_builder::prelude::*;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Every wire kind Haven actually puts on a relay (CLAUDE.md "Protocol Quick
/// Reference"). Kind 450 is deliberately absent: it is embedded in an MLS leaf
/// extension and never published.
const APP_KINDS: [u16; 7] = [0, 445, 1059, 9, 10002, 10050, 30443];

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

async fn start_relay() -> (LocalRelay, String) {
    haven_local_relay::loopback::start_local_relay()
        .await
        .expect("relay starts")
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
        Arc::new(MlsGroupIdSink::disabled()),
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

async fn send(client: &mut Client, text: &str) {
    client
        .send(Message::Text(text.into()))
        .await
        .expect("client send");
}

async fn recv_until(client: &mut Client, what: &str, predicate: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        assert!(!remaining.is_zero(), "timed out waiting for {what}");
        let next = tokio::time::timeout(remaining, client.next())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
        match next {
            Some(Ok(Message::Text(text))) => {
                if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
                    if predicate(&value) {
                        return value;
                    }
                }
            }
            None => panic!("stream ended before {what}"),
            _ => {}
        }
    }
}

fn signed_event(kind: u16) -> Event {
    let keys = Keys::generate();
    let mut tags = vec![Tag::parse(["h", "deadbeefdeadbeefdeadbeefdeadbeef"]).expect("h tag")];
    // Addressable kinds (30000-39999) are keyed by their `d` tag; a relay
    // rejects one without it. Kind 30443 (KeyPackage) is the app's only one.
    if (30_000..40_000).contains(&kind) {
        tags.push(Tag::parse(["d", "slot-0"]).expect("d tag"));
    }
    EventBuilder::new(Kind::Custom(kind), "Y2lwaGVydGV4dA==")
        .tags(tags)
        .sign_with_keys(&keys)
        .expect("event signs")
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

/// A sink that works for `healthy` writes and then fails forever — the disk
/// filling up part-way through a scenario.
struct FailsAfter {
    healthy: usize,
    seen: Arc<AtomicUsize>,
    capture: Capture,
}

impl Write for FailsAfter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.seen.fetch_add(1, Ordering::SeqCst) < self.healthy {
            return self.capture.write(buf);
        }
        Err(io::Error::new(io::ErrorKind::StorageFull, "no space left"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

async fn wait_for_lines(capture: &Capture, at_least: usize) -> Vec<Value> {
    for _ in 0..150 {
        let lines = capture.lines();
        if lines.len() >= at_least {
            return lines;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!(
        "journal never reached {at_least} lines (saw {})",
        capture.lines().len()
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The binary's own `--self-test`, run under `cargo test` too, so a broken
/// instrument reddens the Rust job and not only the lane that uses it.
#[tokio::test(flavor = "multi_thread")]
async fn self_test_passes() {
    haven_local_relay::selftest::run()
        .await
        .expect("--self-test must pass");
}

/// Every wire kind the app publishes survives into the journal verbatim,
/// alongside the relay's answer for each.
#[tokio::test(flavor = "multi_thread")]
async fn journal_holds_every_wire_kind_the_app_publishes() {
    let (_relay, relay_url) = start_relay().await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(relay_url, Arc::clone(&journal)).await;
    let mut client = connect(proxy.local_addr()).await;

    let mut published = Vec::new();
    for kind in APP_KINDS {
        let event = signed_event(kind);
        published.push(event.id.to_hex());
        send(
            &mut client,
            &format!("[\"EVENT\",{}]", event.try_as_json().expect("json")),
        )
        .await;
        let ok = recv_until(&mut client, "OK", |v| v[0] == "OK").await;
        assert_eq!(
            ok[2],
            Value::Bool(true),
            "relay rejected a kind-{kind} event: {ok}"
        );
    }
    // A REQ and a CLOSE, so the c2r verb set matches what the app really sends.
    send(&mut client, r#"["REQ","s1",{"kinds":[445],"limit":1}]"#).await;
    recv_until(&mut client, "EOSE", |v| v[0] == "EOSE").await;
    send(&mut client, r#"["CLOSE","s1"]"#).await;

    // conn_open + 7 EVENT + 7 OK + REQ + (>=1 delivered EVENT) + EOSE + CLOSE.
    let lines = wait_for_lines(&capture, 19).await;
    let frames: Vec<&Value> = lines.iter().filter(|l| l["type"] == TYPE_FRAME).collect();

    for kind in APP_KINDS {
        let recorded = frames.iter().find(|l| {
            l["dir"] == "c2r" && l["frame"][0] == "EVENT" && l["frame"][1]["kind"] == kind
        });
        assert!(recorded.is_some(), "kind {kind} never reached the journal");
    }
    // Verbatim, not summarised: the ids the client sent are the ids recorded.
    let recorded_ids: Vec<String> = frames
        .iter()
        .filter(|l| l["dir"] == "c2r" && l["frame"][0] == "EVENT")
        .filter_map(|l| l["frame"][1]["id"].as_str().map(str::to_owned))
        .collect();
    for id in &published {
        assert!(recorded_ids.contains(id), "event {id} was not recorded");
    }

    for (dir, verb) in [
        ("c2r", "EVENT"),
        ("c2r", "REQ"),
        ("c2r", "CLOSE"),
        ("r2c", "OK"),
        ("r2c", "EOSE"),
    ] {
        assert!(
            frames
                .iter()
                .any(|l| l["dir"] == dir && l["frame"][0] == verb),
            "journal has no {dir} {verb} line"
        );
    }
}

/// FAIL-OPEN, mid-run. The journal works, then the disk fills. Traffic must
/// keep flowing end to end — publish accepted, subscription served — and the
/// journal must say it went degraded rather than pretending it is complete.
#[tokio::test(flavor = "multi_thread")]
async fn recording_that_dies_mid_run_never_stops_traffic() {
    let (_relay, relay_url) = start_relay().await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(FailsAfter {
        healthy: 3,
        seen: Arc::new(AtomicUsize::new(0)),
        capture: capture.clone(),
    })));
    let proxy = start_proxy(relay_url, Arc::clone(&journal)).await;
    let mut client = connect(proxy.local_addr()).await;

    // Traffic well past the point where recording died.
    for _ in 0..6 {
        let event = signed_event(445);
        send(
            &mut client,
            &format!("[\"EVENT\",{}]", event.try_as_json().expect("json")),
        )
        .await;
        let ok = recv_until(&mut client, "OK", |v| v[0] == "OK").await;
        assert_eq!(
            ok[2],
            Value::Bool(true),
            "the relay stopped accepting events once recording died"
        );
    }
    send(&mut client, r#"["REQ","s1",{"kinds":[445]}]"#).await;
    recv_until(&mut client, "a delivered event", |v| v[0] == "EVENT").await;
    recv_until(&mut client, "EOSE", |v| v[0] == "EOSE").await;

    let stats = journal.stats();
    assert_eq!(
        stats.degraded,
        Some(Degraded::WriteFailed),
        "the journal must ADMIT it stopped recording"
    );
    assert_eq!(stats.written, 3, "exactly the pre-failure writes landed");
    assert!(
        stats.observed > 15,
        "sequencing must continue past the failure (observed {})",
        stats.observed
    );
    // Whatever DID land is still well-formed — a truncated journal must be
    // parseable up to the truncation, or a consumer cannot even report it.
    let lines = capture.lines();
    assert_eq!(lines.len(), 3);
    assert!(lines.iter().all(|l| l["wire_seq"].is_u64()));
}

/// The sentinel gives a consumer a snapshot boundary AND lets it exclude its
/// own connection: the ack names the `conn_id` the marker was emitted on.
#[tokio::test(flavor = "multi_thread")]
async fn a_sentinel_bounds_a_snapshot_and_identifies_its_own_connection() {
    let (_relay, relay_url) = start_relay().await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(relay_url, Arc::clone(&journal)).await;

    // "The app": publishes, on its own connection.
    let mut app = connect(proxy.local_addr()).await;
    let event = signed_event(445);
    send(
        &mut app,
        &format!("[\"EVENT\",{}]", event.try_as_json().expect("json")),
    )
    .await;
    recv_until(&mut app, "OK", |v| v[0] == "OK").await;

    // "The oracle": a dedicated connection carrying nothing but the marker.
    let mut oracle = connect(proxy.local_addr()).await;
    send(&mut oracle, &format!(r#"["{SENTINEL_VERB}","tok-abc"]"#)).await;
    let ack = recv_until(&mut oracle, "sentinel ack", |v| v[0] == SENTINEL_ACK_VERB).await;
    let boundary = ack[2].as_u64().expect("ack carries a wire_seq");
    let own_conn = ack[3].as_str().expect("ack carries a conn_id").to_owned();

    // Traffic AFTER the sentinel must not be in the snapshot.
    let late = signed_event(445);
    send(
        &mut app,
        &format!("[\"EVENT\",{}]", late.try_as_json().expect("json")),
    )
    .await;
    recv_until(&mut app, "OK", |v| v[0] == "OK").await;

    // Seven records: conn_open(app), EVENT, OK, conn_open(oracle), sentinel,
    // EVENT(late), OK. The sentinel's ACK is deliberately NOT journalled — it
    // is synthesized by the proxy, and recording it as `r2c` would claim the
    // relay sent it.
    let lines = wait_for_lines(&capture, 7).await;
    let snapshot: Vec<&Value> = lines
        .iter()
        .filter(|l| l["wire_seq"].as_u64().unwrap_or(u64::MAX) <= boundary)
        .collect();

    assert!(
        snapshot
            .iter()
            .any(|l| l["frame"][1]["id"] == event.id.to_hex().as_str()),
        "the pre-sentinel publish must be inside the snapshot"
    );
    assert!(
        !snapshot
            .iter()
            .any(|l| l["frame"][1]["id"] == late.id.to_hex().as_str()),
        "a post-sentinel publish must be outside the snapshot"
    );

    // Excluding the oracle's own connection leaves only app traffic — which is
    // the whole reason the ack names a conn_id.
    let app_only: Vec<&&Value> = snapshot
        .iter()
        .filter(|l| l["conn_id"] != own_conn.as_str())
        .collect();
    assert!(
        app_only
            .iter()
            .all(|l| l["frame"][0].as_str() != Some(SENTINEL_VERB)),
        "excluding the ack's conn_id must remove the marker itself"
    );
    assert!(
        !app_only.is_empty(),
        "excluding the oracle connection must not remove the app's traffic"
    );
}

/// A connection whose upstream is unreachable still binds its `conn_id` to an
/// endpoint. Without this record, "the app dialled a relay that was not
/// configured" leaves no trace at all whenever the dial fails.
#[tokio::test(flavor = "multi_thread")]
async fn a_connection_to_a_dead_upstream_still_records_its_endpoint() {
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    // RESERVED, not merely probed: a released port can be taken by anything on
    // the host, and an upstream that answers turns "the dial failed" — the only
    // thing this test measures — into a 10-second hang.
    let unreachable = RefusedAddr::reserve().expect("reserve an unreachable address");
    let dead = format!("ws://{}", unreachable.addr());
    let proxy = start_proxy(dead.clone(), Arc::clone(&journal)).await;

    // The handshake with the PROXY succeeds; the proxy then fails to reach the
    // upstream and closes us.
    let mut client = connect(proxy.local_addr()).await;
    let _ = tokio::time::timeout(Duration::from_secs(5), client.next()).await;

    let lines = wait_for_lines(&capture, 2).await;
    assert_eq!(lines[0]["type"], "conn_open");
    assert_eq!(lines[0]["relay_url"], dead.as_str());
    assert_eq!(lines[1]["type"], "conn_error");
    assert_eq!(lines[1]["reason"], "upstream connect failed");
    assert_eq!(
        lines[1]["conn_id"], lines[0]["conn_id"],
        "both records must name the same connection"
    );
}

/// The shipped binary must answer SIGTERM with its shutdown summary.
///
/// `stop-wire-proxy.sh` stops the proxy with a plain `kill` (SIGTERM) and tails
/// the log into the step output, because that summary is the ONLY place a run
/// states whether its recorder stayed healthy — a lane whose journal went
/// DEGRADED looks identical to a healthy one everywhere else. A binary that
/// only awaits `ctrl_c()` is SIGINT-only and dies to SIGTERM's default
/// disposition before printing anything, which silently removes that signal.
/// It did exactly that until this test existed.
#[cfg(unix)]
#[test]
fn sigterm_yields_the_shutdown_summary() {
    use std::process::{Command, Stdio};

    let dir = std::env::temp_dir().join(format!("haven-wire-sigterm-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("tmp dir");
    let log_path = dir.join("proxy.log");
    let journal_path = dir.join("journal.ndjson");
    let log = std::fs::File::create(&log_path).expect("log file");

    // Port 0: the child binds whatever the OS gives it, in one step. Handing it
    // a port probed HERE would leave a window for anything on the host to take
    // that port before the child binds, and the child would then exit before
    // ever reaching the signal handling this test is about.
    let mut child = Command::new(env!("CARGO_BIN_EXE_haven-wire-proxy"))
        .env("HAVEN_WIRE_PROXY_PORT", "0")
        .env("HAVEN_WIRE_PROXY_UPSTREAM", "ws://127.0.0.1:1")
        .env("HAVEN_WIRE_JOURNAL", &journal_path)
        .stdout(Stdio::null())
        .stderr(Stdio::from(log))
        .spawn()
        .expect("proxy spawns");

    // Readiness: the proxy prints its journal line after binding every route.
    let mut ready = false;
    for _ in 0..200 {
        if std::fs::read_to_string(&log_path)
            .unwrap_or_default()
            .contains("[haven-wire-proxy] journal:")
        {
            ready = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(ready, "proxy never reported ready");

    let killed = Command::new("kill")
        .args(["-TERM", &child.id().to_string()])
        .status()
        .expect("kill runs");
    assert!(killed.success(), "SIGTERM could not be delivered");

    let status = child.wait().expect("proxy exits");
    let log_text = std::fs::read_to_string(&log_path).unwrap_or_default();
    std::fs::remove_dir_all(&dir).ok();

    assert!(
        status.success(),
        "SIGTERM must be a clean shutdown, not a kill (status: {status})"
    );
    assert!(
        log_text.contains("[haven-wire-proxy] shutting down:"),
        "SIGTERM produced no shutdown summary, so a DEGRADED recorder would \
         leave no trace in the lane log. Log was:\n{log_text}"
    );
}
