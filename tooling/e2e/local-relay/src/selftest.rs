//! `haven-wire-proxy --self-test`: an end-to-end proof of the built binary.
//!
//! The bash guards in `tooling/e2e/ci/*.sh` all carry a hermetic `--self-test`
//! so they cannot rot into a rubber stamp; this is the same discipline for a
//! compiled instrument. It runs a REAL relay, a REAL proxy and a REAL
//! WebSocket client on loopback and asserts the journal that comes out — so
//! `start-wire-proxy.sh` can prove the instrument works on the runner it is
//! about to be trusted on, before the lane depends on it.
//!
//! Every case is named, and every failure names the case. A self-test that
//! prints "OK" without having asserted anything is the exact failure mode this
//! repo keeps finding, so the runner also refuses to pass if it executed fewer
//! cases than it declares.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

use crate::frame::{MLS_GROUP_ID_ACK_VERB, MLS_GROUP_ID_VERB, SENTINEL_ACK_VERB, SENTINEL_VERB};
use crate::journal::{Degraded, WireJournal, TYPE_CONN_OPEN, TYPE_FRAME};
use crate::proxy::{MlsGroupIdSink, Proxy, ProxyConfig, Route};

/// Number of cases [`run`] must execute. A case that stops running is a case
/// that stops proving anything, and silence is how that goes unnoticed.
const DECLARED_CASES: usize = 7;

/// Everything the self-test can conclude.
type Case = Result<(), String>;

/// Runs the whole self-test. `Ok(())` means every case passed.
///
/// # Errors
///
/// Returns a message naming the failing case.
pub async fn run() -> Result<(), String> {
    let mut executed = 0usize;
    let mut failures = Vec::new();

    for (name, result) in [
        ("A round-trip", case_round_trip().await),
        ("B unparseable frame", case_unparseable().await),
        ("C sentinel", case_sentinel().await),
        ("D ordering and conn_id", case_ordering().await),
        ("E fail-open", case_fail_open().await),
        ("F endpoint attribution", case_endpoints().await),
        ("G mls-group-id channel", case_mls_group_id().await),
    ] {
        executed += 1;
        match result {
            Ok(()) => println!("  PASS {name}"),
            Err(err) => {
                eprintln!("  FAIL {name}: {err}");
                failures.push(name);
            }
        }
    }

    if executed != DECLARED_CASES {
        return Err(format!(
            "self-test executed {executed} case(s) but declares {DECLARED_CASES} — \
             a case has been dropped and would have proved nothing silently"
        ));
    }
    if failures.is_empty() {
        println!("haven-wire-proxy: self-test passed ({executed} cases).");
        Ok(())
    } else {
        Err(format!("failing case(s): {}", failures.join(", ")))
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A relay + proxy + journal, all on loopback, all torn down on drop.
struct Rig {
    _relay: nostr_relay_builder::LocalRelay,
    proxy: Proxy,
    journal_path: std::path::PathBuf,
    _dir: TempDir,
}

/// Minimal scoped temp directory (no dev-dependency needed for a binary's
/// own self-test, which must run from the shipped artifact).
struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new(tag: &str) -> Result<Self, String> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let path = std::env::temp_dir().join(format!(
            "haven-wire-proxy-selftest-{}-{tag}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).map_err(|e| format!("temp dir: {:?}", e.kind()))?;
        Ok(Self(path))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

async fn start_relay() -> Result<(nostr_relay_builder::LocalRelay, String), String> {
    // The error is carried through rather than flattened: `loopback` already
    // distinguishes "another process took the port" from "this bind can never
    // work", and a self-test that printed only "relay failed to start" would
    // send whoever reads it looking in the wrong place.
    crate::loopback::start_local_relay()
        .await
        .map_err(|err| format!("relay failed to start: {err}"))
}

/// A properly SIGNED kind-445 event, shaped like the ones Haven publishes
/// (`h` tag plus a NIP-40 `expiration`).
///
/// Signed rather than stubbed because a real relay resets the connection on an
/// invalid signature, which would make the round-trip case prove the relay's
/// strictness instead of the proxy's fidelity.
fn signed_event_json() -> Result<String, String> {
    use nostr_relay_builder::prelude::*;

    let keys = Keys::generate();
    let tags = vec![
        Tag::parse(["h", "deadbeefdeadbeefdeadbeefdeadbeef"]).map_err(|_| "h tag".to_owned())?,
        Tag::parse(["expiration", "4102444800"]).map_err(|_| "expiration tag".to_owned())?,
    ];
    let event = EventBuilder::new(Kind::Custom(445), "Y2lwaGVydGV4dA==")
        .tags(tags)
        .sign_with_keys(&keys)
        .map_err(|_| "event signing failed".to_owned())?;
    event
        .try_as_json()
        .map_err(|_| "event encoding failed".to_owned())
}

/// A minimal upstream that answers every text message with
/// `["ECHO", <the message>]`.
///
/// Used ONLY by the malformed-frame case. A real relay resets the connection
/// on a garbage command, so "did the proxy forward it?" would be unanswerable
/// against `LocalRelay` — and answering it is the whole point: a recorder that
/// swallowed what it could not parse would be worse than no recorder.
async fn start_echo_upstream() -> Result<(String, tokio::task::JoinHandle<()>), String> {
    let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .map_err(|e| format!("echo bind: {:?}", e.kind()))?;
    let addr = listener
        .local_addr()
        .map_err(|e| format!("echo addr: {:?}", e.kind()))?;
    let handle = tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else {
                    return;
                };
                while let Some(Ok(message)) = ws.next().await {
                    if let Message::Text(text) = message {
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
            });
        }
    });
    Ok((format!("ws://{addr}"), handle))
}

async fn rig(tag: &str) -> Result<Rig, String> {
    let dir = TempDir::new(tag)?;
    let journal_path = dir.0.join("journal.ndjson");
    let (relay, relay_url) = start_relay().await?;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let proxy = Proxy::start(
        &ProxyConfig {
            routes: vec![Route {
                listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                upstream: relay_url,
            }],
        },
        journal,
        Arc::new(MlsGroupIdSink::disabled()),
    )
    .await
    .map_err(|e| format!("proxy start: {:?}", e.kind()))?;

    Ok(Rig {
        _relay: relay,
        proxy,
        journal_path,
        _dir: dir,
    })
}

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(addr: SocketAddr) -> Result<Client, String> {
    let url = format!("ws://{addr}");
    let (client, _) = tokio_tungstenite::connect_async(url.as_str())
        .await
        .map_err(|_| format!("client connect to {addr} failed"))?;
    Ok(client)
}

/// Closes a client with the WebSocket closing handshake. Without it the proxy
/// logs a protocol error for every case — the self-test's own untidiness,
/// reading like a finding.
async fn close(mut client: Client) {
    let _ = client.close(None).await;
    while let Some(Ok(_)) = client.next().await {}
}

async fn send(client: &mut Client, text: &str) -> Result<(), String> {
    client
        .send(Message::Text(text.into()))
        .await
        .map_err(|_| "client send failed".to_owned())
}

/// Reads text messages until `predicate` matches, or times out.
async fn recv_until(
    client: &mut Client,
    what: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Result<Value, String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("timed out waiting for {what}"));
        }
        let next = tokio::time::timeout(remaining, client.next())
            .await
            .map_err(|_| format!("timed out waiting for {what}"))?;
        let Some(Ok(Message::Text(text))) = next else {
            match next {
                None => return Err(format!("stream ended before {what}")),
                _ => continue,
            }
        };
        if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
            if predicate(&value) {
                return Ok(value);
            }
        }
    }
}

/// Like [`recv_until`], but returns EVERY text message seen along the way.
///
/// Needed to assert a NEGATIVE ("the sentinel never came back") without a
/// sleep: read until a later, ordered message arrives and inspect what did
/// and did not precede it.
async fn recv_collecting(
    client: &mut Client,
    what: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Result<Vec<String>, String> {
    let mut seen = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("timed out waiting for {what}"));
        }
        let next = tokio::time::timeout(remaining, client.next())
            .await
            .map_err(|_| format!("timed out waiting for {what}"))?;
        let Some(Ok(Message::Text(text))) = next else {
            match next {
                None => return Err(format!("stream ended before {what}")),
                _ => continue,
            }
        };
        seen.push(text.as_str().to_owned());
        if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
            if predicate(&value) {
                return Ok(seen);
            }
        }
    }
}

fn verb_is(value: &Value, verb: &str) -> bool {
    value.get(0).and_then(Value::as_str) == Some(verb)
}

/// Reads the journal, waiting briefly for the proxy's writes to land.
async fn read_journal(path: &Path, min_lines: usize) -> Result<Vec<Value>, String> {
    for _ in 0..100 {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let lines: Vec<Value> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str::<Value>(l).unwrap_or(Value::Null))
            .collect();
        if lines.len() >= min_lines && lines.iter().all(|l| !l.is_null()) {
            return Ok(lines);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    Err(format!(
        "journal never reached {min_lines} well-formed line(s)"
    ))
}

fn frames(lines: &[Value]) -> Vec<&Value> {
    lines.iter().filter(|l| l["type"] == TYPE_FRAME).collect()
}

fn find_verb<'a>(lines: &'a [Value], dir: &str, verb: &str) -> Option<&'a Value> {
    frames(lines)
        .into_iter()
        .find(|l| l["dir"] == dir && l["frame"][0] == verb)
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/// A: a real exchange produces a journal holding every frame type the app
/// sends (EVENT, REQ, CLOSE) and the relay's answers (OK, EOSE).
async fn case_round_trip() -> Case {
    let rig = rig("roundtrip").await?;
    let mut client = connect(rig.proxy.local_addr()).await?;

    let event = signed_event_json()?;
    send(&mut client, &format!(r#"["EVENT",{event}]"#)).await?;
    let ok = recv_until(&mut client, "OK", |v| verb_is(v, "OK")).await?;
    if ok[2] != Value::Bool(true) {
        return Err("the relay rejected a validly signed event".to_owned());
    }

    send(&mut client, r#"["REQ","s1",{"kinds":[445],"limit":10}]"#).await?;
    recv_until(&mut client, "EOSE", |v| verb_is(v, "EOSE")).await?;

    send(&mut client, r#"["CLOSE","s1"]"#).await?;

    // Seven records: conn_open, EVENT(c2r), OK, REQ, EVENT(r2c, the stored
    // event replayed to the new subscription), EOSE, CLOSE.
    let lines = read_journal(&rig.journal_path, 7).await?;

    if lines[0]["type"] != TYPE_CONN_OPEN {
        return Err("first journal line must be the conn_open record".to_owned());
    }
    for (dir, verb) in [
        ("c2r", "EVENT"),
        ("c2r", "REQ"),
        ("c2r", "CLOSE"),
        ("r2c", "EVENT"),
        ("r2c", "OK"),
        ("r2c", "EOSE"),
    ] {
        if find_verb(&lines, dir, verb).is_none() {
            return Err(format!("journal has no {dir} {verb} line"));
        }
    }
    // The EVENT line must hold the event VERBATIM, not a digest of it: an
    // oracle asserting on tags, kinds or signatures has nothing else to read.
    let recorded = find_verb(&lines, "c2r", "EVENT").unwrap_or(&Value::Null);
    let payload = &recorded["frame"][1];
    if payload["kind"] != 445 {
        return Err("EVENT line did not preserve the event kind".to_owned());
    }
    let tag_names: Vec<&str> = payload["tags"]
        .as_array()
        .map(|tags| tags.iter().filter_map(|t| t[0].as_str()).collect())
        .unwrap_or_default();
    if !tag_names.contains(&"h") || !tag_names.contains(&"expiration") {
        return Err(format!("EVENT line lost its tags (saw {tag_names:?})"));
    }
    if payload["sig"].as_str().is_none() || payload["pubkey"].as_str().is_none() {
        return Err("EVENT line lost the signature/pubkey fields".to_owned());
    }
    if recorded["raw_len"].as_u64().unwrap_or(0) == 0 {
        return Err("raw_len must be the byte length of the original frame".to_owned());
    }
    close(client).await;
    Ok(())
}

/// B: a frame that is not a Nostr frame is recorded — never dropped — AND
/// still forwarded, because the proxy is transparent, not a validator.
async fn case_unparseable() -> Case {
    const GARBAGE: &str = "<<< definitely not json >>>";

    let dir = TempDir::new("unparseable")?;
    let journal_path = dir.0.join("journal.ndjson");
    // Echo upstream, not a relay: a relay RESETS the connection on a garbage
    // command, so "was it forwarded?" would be unanswerable — and that is the
    // question, because a recorder that swallowed what it could not parse
    // would be worse than no recorder at all.
    let (upstream, echo) = start_echo_upstream().await?;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let proxy = Proxy::start(
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
    .map_err(|e| format!("proxy start: {:?}", e.kind()))?;

    let mut client = connect(proxy.local_addr()).await?;
    send(&mut client, GARBAGE).await?;
    let echoed = recv_until(&mut client, "echo of the malformed frame", |v| {
        verb_is(v, "ECHO")
    })
    .await?;
    if echoed[1] != GARBAGE {
        return Err("the malformed frame was altered in flight".to_owned());
    }

    let lines = read_journal(&journal_path, 2).await?;
    let finding = frames(&lines)
        .into_iter()
        .find(|l| l["frame"].is_null())
        .ok_or_else(|| "no frame:null line for the malformed message".to_owned())?;

    if finding["raw_preview"] != GARBAGE {
        return Err("frame:null line carries no faithful raw_preview".to_owned());
    }
    if finding["raw_len"].as_u64() != Some(GARBAGE.len() as u64) {
        return Err("frame:null line carries the wrong raw_len".to_owned());
    }
    if finding["dir"] != "c2r" {
        return Err("the malformed frame lost its direction".to_owned());
    }

    close(client).await;
    echo.abort();
    Ok(())
}

/// C: the sentinel lands in the journal at a known `wire_seq`, is answered
/// with that seq and the connection's id, and NEVER reaches the upstream.
///
/// The upstream is the ECHO server, not `LocalRelay`, and that is the whole
/// point of this case. `LocalRelay` ignores an unknown verb in silence, so an
/// earlier version of this case looked for a `NOTICE` that no relay was ever
/// going to send — a check that could not fail, guarding the single most
/// important claim the sentinel design makes ("no relay ever sees it"). The
/// echo upstream answers EVERY message, so a forwarded marker is directly
/// observable, and a later ordered message provides the barrier that makes
/// the negative deterministic instead of a sleep.
async fn case_sentinel() -> Case {
    const TOKEN: &str = "HAVEN_WIRE_SENTINEL:tokselftest";

    let dir = TempDir::new("sentinel")?;
    let journal_path = dir.0.join("journal.ndjson");
    let (upstream, echo) = start_echo_upstream().await?;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let proxy = Proxy::start(
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
    .map_err(|e| format!("proxy start: {:?}", e.kind()))?;
    let mut client = connect(proxy.local_addr()).await?;

    // Ordinary traffic first, and confirm the upstream really is receiving —
    // otherwise "the sentinel did not arrive upstream" would be true of
    // everything and prove nothing.
    send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await?;
    recv_until(&mut client, "the echo of the pre-sentinel REQ", |v| {
        verb_is(v, "ECHO") && v[1].as_str().is_some_and(|t| t.contains("before"))
    })
    .await?;

    send(&mut client, &format!(r#"["{SENTINEL_VERB}","{TOKEN}"]"#)).await?;
    let ack = recv_until(&mut client, "sentinel ack", |v| {
        verb_is(v, SENTINEL_ACK_VERB)
    })
    .await?;

    // THE BARRIER. The echo upstream answers messages in order on one
    // connection, so once the echo of a message sent AFTER the sentinel comes
    // back, the sentinel's own echo would already have arrived had it been
    // forwarded. No sleep, no flake.
    send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await?;
    let seen = recv_collecting(&mut client, "the echo of the post-sentinel REQ", |v| {
        verb_is(v, "ECHO") && v[1].as_str().is_some_and(|t| t.contains("after"))
    })
    .await?;
    if seen
        .iter()
        .any(|m| m.contains("ECHO") && m.contains(SENTINEL_VERB))
    {
        return Err(
            "the sentinel was FORWARDED upstream — the marker must never reach a relay".to_owned(),
        );
    }

    if ack[1] != TOKEN {
        return Err("ack did not echo the token".to_owned());
    }
    let seq = ack[2]
        .as_u64()
        .ok_or_else(|| "ack carries no wire_seq".to_owned())?;
    let conn = ack[3]
        .as_str()
        .ok_or_else(|| "ack carries no conn_id".to_owned())?
        .to_owned();

    let lines = read_journal(&journal_path, 6).await?;
    let marker = frames(&lines)
        .into_iter()
        .find(|l| l["frame"][0] == SENTINEL_VERB)
        .ok_or_else(|| "sentinel is not in the journal".to_owned())?;

    if marker["wire_seq"].as_u64() != Some(seq) {
        return Err("the acked wire_seq is not the sentinel line's".to_owned());
    }
    if marker["frame"][1] != TOKEN {
        return Err("the sentinel line lost its token".to_owned());
    }
    if marker["conn_id"].as_str() != Some(conn.as_str()) {
        return Err("the acked conn_id is not the sentinel line's".to_owned());
    }
    if marker["dir"] != "c2r" {
        return Err("the sentinel must be recorded as client-originated".to_owned());
    }
    // The ACK is synthesized by the proxy and must NOT be journalled: recording
    // it as `r2c` would claim the relay sent it.
    if frames(&lines)
        .into_iter()
        .any(|l| l["frame"][0] == SENTINEL_ACK_VERB)
    {
        return Err("the sentinel ACK was journalled — it is not observed traffic".to_owned());
    }
    // Everything at or below the marker is the snapshot a consumer asserts on,
    // and the post-sentinel traffic must fall OUTSIDE it — an inert sentinel
    // that bounded nothing would pass every other check in this case.
    let below: Vec<&Value> = frames(&lines)
        .into_iter()
        .filter(|l| l["wire_seq"].as_u64().unwrap_or(u64::MAX) <= seq)
        .collect();
    if below.len() < 3 {
        return Err("the sentinel snapshot is implausibly small".to_owned());
    }
    if below.iter().any(|l| l["frame"][1] == "after") {
        return Err("post-sentinel traffic landed INSIDE the snapshot".to_owned());
    }
    if !below.iter().any(|l| l["frame"][1] == "before") {
        return Err("pre-sentinel traffic fell OUTSIDE the snapshot".to_owned());
    }

    close(client).await;
    echo.abort();
    Ok(())
}

/// D: `wire_seq` is monotonic across connections and `conn_id` is stable
/// within one and distinct between two.
async fn case_ordering() -> Case {
    let rig = rig("ordering").await?;
    let addr = rig.proxy.local_addr();

    let mut first = connect(addr).await?;
    send(&mut first, r#"["REQ","a",{"kinds":[1]}]"#).await?;
    recv_until(&mut first, "EOSE", |v| verb_is(v, "EOSE")).await?;

    let mut second = connect(addr).await?;
    send(&mut second, r#"["REQ","b",{"kinds":[2]}]"#).await?;
    recv_until(&mut second, "EOSE", |v| verb_is(v, "EOSE")).await?;

    send(&mut first, r#"["CLOSE","a"]"#).await?;

    let lines = read_journal(&rig.journal_path, 7).await?;

    let seqs: Vec<u64> = lines
        .iter()
        .map(|l| l["wire_seq"].as_u64().unwrap_or(u64::MAX))
        .collect();
    if !seqs.windows(2).all(|w| w[0] < w[1]) {
        return Err(format!("wire_seq is not strictly increasing: {seqs:?}"));
    }
    if seqs.first() != Some(&0) {
        return Err("wire_seq does not start at 0".to_owned());
    }

    let conns: std::collections::BTreeSet<&str> =
        lines.iter().filter_map(|l| l["conn_id"].as_str()).collect();
    if conns.len() != 2 {
        return Err(format!("expected 2 distinct conn_ids, saw {conns:?}"));
    }
    // Stability: the first connection's REQ and its later CLOSE must carry the
    // SAME conn_id, or a consumer cannot attribute a session at all.
    let req_conn = frames(&lines)
        .into_iter()
        .find(|l| l["frame"][0] == "REQ" && l["frame"][1] == "a")
        .and_then(|l| l["conn_id"].as_str())
        .ok_or_else(|| "no REQ line for the first connection".to_owned())?;
    let close_conn = frames(&lines)
        .into_iter()
        .find(|l| l["frame"][0] == "CLOSE" && l["frame"][1] == "a")
        .and_then(|l| l["conn_id"].as_str())
        .ok_or_else(|| "no CLOSE line for the first connection".to_owned())?;
    if req_conn != close_conn {
        return Err("conn_id is not stable across one connection".to_owned());
    }
    close(first).await;
    close(second).await;
    Ok(())
}

/// E: THE fail-open proof. The journal path is unwritable, so recording is
/// impossible — and traffic must still flow end to end.
async fn case_fail_open() -> Case {
    let dir = TempDir::new("failopen")?;
    // A DIRECTORY where the journal file should be: opening it for append
    // fails with EISDIR on every supported platform, and no privilege can
    // make it succeed (unlike a chmod, which root defeats).
    let journal_path = dir.0.join("journal.ndjson");
    std::fs::create_dir_all(&journal_path).map_err(|e| format!("fixture: {:?}", e.kind()))?;

    let (relay, relay_url) = start_relay().await?;
    let journal = Arc::new(WireJournal::open(&journal_path));
    if !journal.is_degraded() {
        return Err("fixture did not actually make the journal unwritable".to_owned());
    }

    let proxy = Proxy::start(
        &ProxyConfig {
            routes: vec![Route {
                listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                upstream: relay_url,
            }],
        },
        Arc::clone(&journal),
        Arc::new(MlsGroupIdSink::disabled()),
    )
    .await
    .map_err(|e| format!("proxy start: {:?}", e.kind()))?;

    // The SAME end-to-end exchange as case A, against a REAL relay: publish a
    // signed event, get an accepting OK, subscribe, get an EOSE. Anything
    // weaker (a ping, a connect) would show the socket was open, not that the
    // product still works with its instrument dead.
    let mut client = connect(proxy.local_addr()).await?;
    let event = signed_event_json()?;
    send(&mut client, &format!(r#"["EVENT",{event}]"#)).await?;
    let ok = recv_until(&mut client, "OK", |v| verb_is(v, "OK")).await?;
    if ok[2] != Value::Bool(true) {
        return Err("the relay did not accept the event with recording dead".to_owned());
    }

    send(&mut client, r#"["REQ","s1",{"kinds":[445]}]"#).await?;
    // The stored event is delivered BEFORE the EOSE, and `recv_until`
    // discards whatever it skips past, so wait for the EVENT first: that is
    // the r2c half of the proof.
    recv_until(
        &mut client,
        "the event echoed back to the subscriber",
        |v| verb_is(v, "EVENT"),
    )
    .await?;
    recv_until(&mut client, "EOSE", |v| verb_is(v, "EOSE")).await?;

    let stats = journal.stats();
    if stats.written != 0 {
        return Err("fixture wrote to a journal it could not open".to_owned());
    }
    if stats.observed < 4 {
        return Err(format!(
            "traffic did not flow with recording dead (observed {})",
            stats.observed
        ));
    }
    if stats.degraded != Some(Degraded::OpenFailed) {
        return Err(format!("wrong degraded reason: {:?}", stats.degraded));
    }
    close(client).await;
    drop(relay);
    Ok(())
}

/// F: two relays behind two ports share ONE journal and one sequence space,
/// and every line names the endpoint it belongs to. Without this a
/// publish-target containment assertion cannot be written at all.
async fn case_endpoints() -> Case {
    let dir = TempDir::new("endpoints")?;
    let journal_path = dir.0.join("journal.ndjson");
    let (relay_a, url_a) = start_relay().await?;
    let (relay_b, url_b) = start_relay().await?;

    let journal = Arc::new(WireJournal::open(&journal_path));
    let proxy = Proxy::start(
        &ProxyConfig {
            routes: vec![
                Route {
                    listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                    upstream: url_a.clone(),
                },
                Route {
                    listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                    upstream: url_b.clone(),
                },
            ],
        },
        journal,
        Arc::new(MlsGroupIdSink::disabled()),
    )
    .await
    .map_err(|e| format!("proxy start: {:?}", e.kind()))?;

    let bound: Vec<SocketAddr> = proxy.bound_routes().iter().map(|r| r.listen).collect();
    if bound.len() != 2 || bound[0] == bound[1] {
        return Err("two routes did not bind two distinct ports".to_owned());
    }

    let mut client_a = connect(bound[0]).await?;
    send(&mut client_a, r#"["REQ","ra",{"kinds":[1]}]"#).await?;
    recv_until(&mut client_a, "EOSE", |v| verb_is(v, "EOSE")).await?;

    let mut client_b = connect(bound[1]).await?;
    send(&mut client_b, r#"["REQ","rb",{"kinds":[1]}]"#).await?;
    recv_until(&mut client_b, "EOSE", |v| verb_is(v, "EOSE")).await?;

    let lines = read_journal(&journal_path, 6).await?;
    let for_a: Vec<&Value> = frames(&lines)
        .into_iter()
        .filter(|l| l["frame"][1] == "ra")
        .collect();
    let for_b: Vec<&Value> = frames(&lines)
        .into_iter()
        .filter(|l| l["frame"][1] == "rb")
        .collect();
    if for_a.is_empty() || for_b.is_empty() {
        return Err("traffic for one of the two relays never appeared".to_owned());
    }
    if for_a.iter().any(|l| l["relay_url"] != url_a.as_str()) {
        return Err("relay A traffic is attributed to the wrong endpoint".to_owned());
    }
    if for_b.iter().any(|l| l["relay_url"] != url_b.as_str()) {
        return Err("relay B traffic is attributed to the wrong endpoint".to_owned());
    }
    // One sequence space across both routes: a consumer must be able to order
    // relay A's traffic against relay B's.
    let seqs: Vec<u64> = lines
        .iter()
        .map(|l| l["wire_seq"].as_u64().unwrap_or(u64::MAX))
        .collect();
    if !seqs.windows(2).all(|w| w[0] < w[1]) {
        return Err("wire_seq is not a single space across routes".to_owned());
    }

    close(client_a).await;
    close(client_b).await;
    drop(relay_a);
    drop(relay_b);
    Ok(())
}

/// G: the device→host MLS-group-id channel, proved on THIS runner.
///
/// Three claims, all of which the lane's Rule-4 assertion rests on and none of
/// which a unit test can establish:
///
/// * the declared id reaches the SIDECAR (a lane with no sidecar has no ground
///   truth and C5.8 would scan for an empty set of needles),
/// * it never reaches the JOURNAL (the journal is the corpus C5.8 scans; the
///   announcement appearing there would make the oracle find itself), and
/// * it never reaches the UPSTREAM (Security Rule 4, committed or not
///   committed by this proxy).
///
/// The upstream is the ECHO server rather than `LocalRelay` for the same
/// reason case C uses it: a real relay ignores an unknown verb in silence, so
/// a forwarded declaration would be invisible and the most important claim
/// here would be guarded by a check that cannot fail.
async fn case_mls_group_id() -> Case {
    // 32 bytes, the size MDK mints. Declared UPPERCASE to prove normalization.
    const ID: &str = "A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90";
    // Below the oracle's 32-hex substring floor, so it must be refused.
    const SHORT: &str = "deadbeefdeadbeef";

    let dir = TempDir::new("mlsgroupid")?;
    let journal_path = dir.0.join("journal.ndjson");
    let sidecar_path = dir.0.join("ids.txt");
    let (upstream, echo) = start_echo_upstream().await?;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let sink = Arc::new(MlsGroupIdSink::new(sidecar_path.clone()));
    let proxy = Proxy::start(
        &ProxyConfig {
            routes: vec![Route {
                listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                upstream,
            }],
        },
        journal,
        Arc::clone(&sink),
    )
    .await
    .map_err(|e| format!("proxy start: {:?}", e.kind()))?;
    let mut client = connect(proxy.local_addr()).await?;

    // Confirm the upstream really is receiving, or "the declaration did not
    // arrive" would be true of everything and prove nothing.
    send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await?;
    recv_until(&mut client, "the echo of the pre-declaration REQ", |v| {
        verb_is(v, "ECHO") && v[1].as_str().is_some_and(|t| t.contains("before"))
    })
    .await?;

    send(&mut client, &format!(r#"["{MLS_GROUP_ID_VERB}","{ID}"]"#)).await?;
    let ack = recv_until(&mut client, "mls-group-id ack", |v| {
        verb_is(v, MLS_GROUP_ID_ACK_VERB)
    })
    .await?;
    if ack[1].as_str() != Some(ID.to_ascii_lowercase().as_str()) {
        return Err("the ack did not echo the NORMALIZED id".to_owned());
    }

    // A value the oracle would reject must be rejected here, so a lane can
    // never be handed a needle that finds unrelated tokens by coincidence.
    send(
        &mut client,
        &format!(r#"["{MLS_GROUP_ID_VERB}","{SHORT}"]"#),
    )
    .await?;

    // THE BARRIER: the echo upstream answers in order on one connection, so
    // once the echo of a message sent AFTER both declarations comes back, a
    // forwarded declaration would already have arrived. No sleep, no flake.
    send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await?;
    let seen = recv_collecting(&mut client, "the echo of the post-declaration REQ", |v| {
        verb_is(v, "ECHO") && v[1].as_str().is_some_and(|t| t.contains("after"))
    })
    .await?;

    if seen
        .iter()
        .any(|m| m.contains("ECHO") && m.contains(MLS_GROUP_ID_VERB))
    {
        return Err(
            "the MLS group id was FORWARDED upstream — Security Rule 4 says the real \
             group id must never reach a relay, and this interception is what guarantees it"
                .to_owned(),
        );
    }
    if seen.iter().any(|m| m.contains(SHORT)) {
        return Err("a REFUSED declaration was forwarded upstream".to_owned());
    }
    if seen
        .iter()
        .filter(|m| m.contains(MLS_GROUP_ID_ACK_VERB))
        .count()
        != 0
    {
        return Err("a refused declaration was acked".to_owned());
    }

    // The journal must hold the surrounding traffic and none of the ids: its
    // silence only means something if it recorded anything at all.
    let text = std::fs::read_to_string(&journal_path).unwrap_or_default();
    if !text.contains("\"after\"") {
        return Err("the journal did not record the barrier".to_owned());
    }
    for needle in [ID, &ID.to_ascii_lowercase(), SHORT, MLS_GROUP_ID_VERB] {
        if text.contains(needle) {
            return Err(
                "an MLS group id declaration reached the JOURNAL. C5.8 scans that file \
                 for exactly this value, so recording it makes Security Rule 4 read as \
                 satisfied by the instrument talking to itself."
                    .to_owned(),
            );
        }
    }

    let recorded = std::fs::read_to_string(&sidecar_path).unwrap_or_default();
    let lines: Vec<&str> = recorded.lines().filter(|l| !l.is_empty()).collect();
    if lines != vec![ID.to_ascii_lowercase().as_str()] {
        return Err(format!(
            "the sidecar holds {} line(s); it must hold exactly the one accepted id, \
             lowercased",
            lines.len()
        ));
    }
    let stats = sink.stats();
    if stats.distinct != 1 || stats.refused != 1 || stats.lost != 0 {
        return Err(format!(
            "sidecar stats are wrong: {} distinct, {} refused, {} lost",
            stats.distinct, stats.refused, stats.lost
        ));
    }

    close(client).await;
    echo.abort();
    Ok(())
}
