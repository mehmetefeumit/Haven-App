//! End-to-end proof of the device→host MLS-group-id control channel.
//!
//! The unit tests in `src/` prove the sink and the validator. These prove the
//! two properties that only exist once the sink is wired into the pump, and
//! that no amount of unit testing can establish:
//!
//! 1. **The declared id NEVER lands in the journal.** The journal is the
//!    corpus the correlation oracle's C5.8 scans for that exact string in
//!    order to assert Security Rule 4. If the announcement were recorded, the
//!    oracle would find the harness talking to itself, and a genuine leak
//!    would be indistinguishable from the declaration.
//!
//! 2. **The declared id is NEVER forwarded upstream.** Security Rule 4 says
//!    the real MLS group id must never reach a relay. Here that is not a
//!    property of the app under test — it is a property of this proxy, and a
//!    forwarding bug would be a live protocol violation committed by the
//!    instrument.
//!
//! Both are ASSERTIONS OF ABSENCE, so both need a barrier rather than a sleep:
//! the upstream is an ECHO server that answers every message, and a later,
//! ordered message provides the moment by which a forwarded declaration would
//! already have come back.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use haven_local_relay::frame::{MLS_GROUP_ID_ACK_VERB, MLS_GROUP_ID_VERB};
use haven_local_relay::journal::WireJournal;
use haven_local_relay::proxy::{MlsGroupIdSink, Proxy, ProxyConfig, Route};
use nostr_relay_builder::prelude::*;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A 32-byte id, the size MDK mints.
const ALICE_GROUP: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
/// A second circle. A scenario has more than one, and every one has to arrive.
const BOB_GROUP: &str = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A temp directory scoped to one test.
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let path = std::env::temp_dir().join(format!(
            "haven-wire-proxy-mlsid-{}-{tag}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).expect("temp dir");
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

async fn start_relay() -> (LocalRelay, String) {
    haven_local_relay::loopback::start_local_relay()
        .await
        .expect("relay starts")
}

/// An upstream that answers every TEXT message with `["ECHO", <the message>]`.
///
/// A real relay ignores an unknown verb in silence, so "did the proxy forward
/// the declaration?" would be unanswerable against it — and answering it is
/// the whole point of this file. The echo server makes a forwarded message
/// directly observable at the client.
async fn start_echo_upstream() -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("echo bind");
    let addr = listener.local_addr().expect("echo addr");
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
    (format!("ws://{addr}"), handle)
}

async fn start_proxy(
    upstream: String,
    journal: Arc<WireJournal>,
    mls_group_ids: Arc<MlsGroupIdSink>,
) -> Proxy {
    Proxy::start(
        &ProxyConfig {
            routes: vec![Route {
                listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                upstream,
            }],
        },
        journal,
        mls_group_ids,
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

fn declare(id: &str) -> String {
    format!(r#"["{MLS_GROUP_ID_VERB}","{id}"]"#)
}

/// Reads text messages until `predicate` matches, returning EVERYTHING seen
/// along the way — which is what makes an assertion of absence deterministic.
async fn recv_collecting(
    client: &mut Client,
    what: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Vec<String> {
    let mut seen = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        assert!(
            !remaining.is_zero(),
            "timed out waiting for {what}; saw {seen:?}"
        );
        let next = tokio::time::timeout(remaining, client.next())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {what}; saw {seen:?}"));
        match next {
            Some(Ok(Message::Text(text))) => {
                seen.push(text.as_str().to_owned());
                if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
                    if predicate(&value) {
                        return seen;
                    }
                }
            }
            None => panic!("stream ended before {what}; saw {seen:?}"),
            _ => {}
        }
    }
}

/// The journal's raw TEXT, waiting briefly for the proxy's writes to land.
///
/// Deliberately unparsed: C5.8 is a substring scan over the file, so the thing
/// to assert on is the file's bytes, not a structural view of them. A leak
/// through some field these tests forgot to inspect would still be a leak.
async fn journal_text(path: &Path, at_least: usize) -> String {
    for _ in 0..200 {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        if text.lines().filter(|l| !l.trim().is_empty()).count() >= at_least {
            return text;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("journal never reached {at_least} line(s)");
}

fn sidecar_lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

// ---------------------------------------------------------------------------
// The two properties
// ---------------------------------------------------------------------------

/// PROPERTY 1 + the sidecar contract: several circles' ids reach the host file,
/// one lowercase hex per line and de-duplicated, and NONE of them reaches the
/// journal.
#[tokio::test(flavor = "multi_thread")]
async fn declared_ids_reach_the_sidecar_and_never_the_journal() {
    let dir = TempDir::new("journal");
    let journal_path = dir.0.join("journal.ndjson");
    let sidecar_path = dir.0.join("ids.txt");
    let (_relay, relay_url) = start_relay().await;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let sink = Arc::new(MlsGroupIdSink::new(sidecar_path.clone()));
    let proxy = start_proxy(relay_url, journal, Arc::clone(&sink)).await;

    let mut client = connect(proxy.local_addr()).await;

    // Ordinary traffic, so the journal is non-empty and "the id is absent" is
    // not merely "the file is empty".
    send(&mut client, r#"["REQ","before",{"kinds":[445]}]"#).await;
    recv_collecting(&mut client, "EOSE for the pre-declaration REQ", |v| {
        v[0] == "EOSE"
    })
    .await;

    send(&mut client, &declare(ALICE_GROUP)).await;
    recv_collecting(&mut client, "the ack for Alice's circle", |v| {
        v[0] == MLS_GROUP_ID_ACK_VERB
    })
    .await;

    // A SECOND circle, declared UPPERCASE, and then a repeat of the first.
    send(&mut client, &declare(&BOB_GROUP.to_uppercase())).await;
    recv_collecting(&mut client, "the ack for Bob's circle", |v| {
        v[0] == MLS_GROUP_ID_ACK_VERB && v[1] == BOB_GROUP
    })
    .await;
    send(&mut client, &declare(ALICE_GROUP)).await;
    recv_collecting(&mut client, "the ack for the repeat", |v| {
        v[0] == MLS_GROUP_ID_ACK_VERB && v[1] == ALICE_GROUP
    })
    .await;

    // A later REQ is the barrier: it is journalled, so once it appears the
    // recorder has demonstrably processed everything sent before it.
    send(&mut client, r#"["REQ","after",{"kinds":[445]}]"#).await;
    recv_collecting(&mut client, "EOSE for the post-declaration REQ", |v| {
        v[0] == "EOSE"
    })
    .await;

    let text = journal_text(&journal_path, 5).await;

    assert!(
        text.contains("\"before\""),
        "the journal must hold the traffic around the declaration, or its silence proves nothing"
    );
    assert!(text.contains("\"after\""), "the barrier must be journalled");
    for id in [ALICE_GROUP, BOB_GROUP] {
        assert!(
            !text.contains(id),
            "the declared MLS group id reached the JOURNAL. C5.8 scans that file for \
             exactly this value to assert Security Rule 4; recording the announcement \
             makes the assertion an instrument talking to itself."
        );
        assert!(
            !text.to_lowercase().contains(id),
            "the declared MLS group id reached the journal in some other case"
        );
    }
    assert!(
        !text.contains(MLS_GROUP_ID_VERB),
        "even the control VERB must not appear in the journal: an oracle enumerating \
         frame[0] would then have to learn to ignore it"
    );

    // ...and the sidecar has all of it, once each, normalized.
    assert_eq!(
        sidecar_lines(&sidecar_path),
        vec![ALICE_GROUP.to_owned(), BOB_GROUP.to_owned()],
        "every circle's id must reach the host, lowercase and de-duplicated"
    );
    assert_eq!(sink.stats().distinct, 2);
    assert_eq!(sink.stats().refused, 0);
}

/// PROPERTY 2: the declaration never reaches the upstream.
///
/// Not a test-harness nicety — Security Rule 4. The echo upstream answers
/// everything, and the echo of a LATER message is the barrier that makes the
/// negative deterministic rather than a sleep.
#[tokio::test(flavor = "multi_thread")]
async fn a_declared_id_is_never_forwarded_upstream() {
    let dir = TempDir::new("forward");
    let sidecar_path = dir.0.join("ids.txt");
    let (upstream, echo) = start_echo_upstream().await;
    let journal = Arc::new(WireJournal::open(&dir.0.join("journal.ndjson")));
    let sink = Arc::new(MlsGroupIdSink::new(sidecar_path));
    let proxy = start_proxy(upstream, journal, sink).await;

    let mut client = connect(proxy.local_addr()).await;

    // Prove the upstream really is receiving first, or "the declaration did
    // not arrive" would be true of everything and prove nothing.
    send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await;
    recv_collecting(&mut client, "the echo of the pre-declaration REQ", |v| {
        v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("before"))
    })
    .await;

    send(&mut client, &declare(ALICE_GROUP)).await;
    recv_collecting(&mut client, "the ack", |v| v[0] == MLS_GROUP_ID_ACK_VERB).await;

    send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await;
    let seen = recv_collecting(&mut client, "the echo of the post-declaration REQ", |v| {
        v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("after"))
    })
    .await;

    for message in &seen {
        assert!(
            !(message.contains("ECHO") && message.contains(ALICE_GROUP)),
            "the real MLS group id was FORWARDED to the upstream. That is Security \
             Rule 4 violated by the recorder itself, not a harness defect: {message}"
        );
        assert!(
            !(message.contains("ECHO") && message.contains(MLS_GROUP_ID_VERB)),
            "the control verb was forwarded upstream: {message}"
        );
    }

    echo.abort();
}

/// A declaration the PARSER cannot read is still a declaration.
///
/// Interception was once keyed on `Observation.mls_group_id`, which is set only
/// when the payload parses as a JSON array whose first element is a string.
/// Malformed JSON, a non-array, or a Binary frame therefore fell through and
/// was BOTH journalled — `raw_preview` keeps 200 chars against a ~95-char
/// declaration, i.e. the whole id — AND forwarded to the relay. That made Rule
/// 4 a property of the parser rather than of the verb. These are the shapes
/// that used to escape.
#[tokio::test(flavor = "multi_thread")]
async fn an_unparseable_declaration_is_intercepted_not_relayed_or_recorded() {
    let dir = TempDir::new("malformed");
    let sidecar_path = dir.0.join("ids.txt");
    let journal_path = dir.0.join("journal.ndjson");
    let (upstream, echo) = start_echo_upstream().await;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let sink = Arc::new(MlsGroupIdSink::new(sidecar_path.clone()));
    let proxy = start_proxy(upstream, journal, sink).await;

    let mut client = connect(proxy.local_addr()).await;

    // Truncated JSON — the array never closes, so serde refuses it.
    send(
        &mut client,
        &format!(r#"["{MLS_GROUP_ID_VERB}","{ALICE_GROUP}"#),
    )
    .await;
    // A JSON object rather than an array: parses, wrong shape.
    send(
        &mut client,
        &format!(r#"{{"verb":"{MLS_GROUP_ID_VERB}","id":"{ALICE_GROUP}"}}"#),
    )
    .await;

    // Prove the connection is still live and the upstream still echoing, or
    // "the declaration did not arrive" would be true of everything.
    send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await;
    let seen = recv_collecting(&mut client, "the echo of the post-declaration REQ", |v| {
        v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("after"))
    })
    .await;

    for message in &seen {
        assert!(
            !message.contains(ALICE_GROUP),
            "an unparseable declaration carried the real MLS group id to the \
             upstream. Rule 4 is broken by the recorder itself: {message}"
        );
    }

    let journal_text = std::fs::read_to_string(&journal_path).unwrap_or_default();
    assert!(
        !journal_text.contains(ALICE_GROUP),
        "an unparseable declaration put the real MLS group id in the JOURNAL \
         (raw_preview keeps 200 chars). C5.8 would then find the harness's own \
         announcement and report a leak that never happened."
    );

    // Refused, so nothing is recorded as ground truth either.
    let sidecar = std::fs::read_to_string(&sidecar_path).unwrap_or_default();
    assert!(
        !sidecar.contains(ALICE_GROUP),
        "an unparseable declaration was accepted as ground truth"
    );

    echo.abort();
}

/// Too short for the oracle's substring floor: such a needle would match
/// unrelated hex tokens by coincidence and report leaks that are not there.
const SHORT: &str = "deadbeefdeadbeef";

/// A REFUSED declaration is refused all the way down: no ack, nothing in the
/// sidecar, nothing in the journal, nothing on the wire — and it is counted,
/// so the shutdown summary says the lane has no Rule-4 ground truth.
#[tokio::test(flavor = "multi_thread")]
async fn a_refused_declaration_is_still_intercepted_and_is_reported() {
    let dir = TempDir::new("refused");
    let journal_path = dir.0.join("journal.ndjson");
    let sidecar_path = dir.0.join("ids.txt");
    let (upstream, echo) = start_echo_upstream().await;
    let journal = Arc::new(WireJournal::open(&journal_path));
    let sink = Arc::new(MlsGroupIdSink::new(sidecar_path.clone()));
    let proxy = start_proxy(upstream, journal, Arc::clone(&sink)).await;

    let mut client = connect(proxy.local_addr()).await;
    send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await;
    recv_collecting(&mut client, "the echo of the pre-declaration REQ", |v| {
        v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("before"))
    })
    .await;

    send(&mut client, &declare(SHORT)).await;

    send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await;
    let seen = recv_collecting(&mut client, "the echo of the post-declaration REQ", |v| {
        v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("after"))
    })
    .await;

    assert!(
        !seen.iter().any(|m| m.contains(MLS_GROUP_ID_ACK_VERB)),
        "a refused declaration must NOT be acked: an ack has to mean the host will \
         see the id, or a lane would run C5.8 against a needle set it never got"
    );
    assert!(
        !seen.iter().any(|m| m.contains(MLS_GROUP_ID_VERB)),
        "a MALFORMED declaration must be intercepted just like a well-formed one — \
         the verb alone is enough to know a Rule-4 value was meant"
    );

    let text = journal_text(&journal_path, 4).await;
    assert!(text.contains("\"after\""), "the barrier must be journalled");
    assert!(
        !text.contains(SHORT) && !text.contains(MLS_GROUP_ID_VERB),
        "a refused declaration must not be journalled either"
    );

    assert!(
        !sidecar_path.exists(),
        "a refused value must not even create the sidecar"
    );
    let stats = sink.stats();
    assert_eq!(
        stats.refused, 1,
        "the refusal must be counted, not swallowed"
    );
    assert_eq!(stats.distinct, 0);

    echo.abort();
}

/// Two connections, one sidecar: the ids are de-duplicated ACROSS connections,
/// because a scenario re-declares on every reconnect and the oracle takes the
/// file as a set of needles.
#[tokio::test(flavor = "multi_thread")]
async fn the_sidecar_is_shared_and_deduplicated_across_connections() {
    let dir = TempDir::new("shared");
    let sidecar_path = dir.0.join("ids.txt");
    let (_relay, relay_url) = start_relay().await;
    let journal = Arc::new(WireJournal::open(&dir.0.join("journal.ndjson")));
    let sink = Arc::new(MlsGroupIdSink::new(sidecar_path.clone()));
    let proxy = start_proxy(relay_url, journal, Arc::clone(&sink)).await;

    for _ in 0..3 {
        let mut client = connect(proxy.local_addr()).await;
        send(&mut client, &declare(ALICE_GROUP)).await;
        recv_collecting(&mut client, "the ack", |v| {
            v[0] == MLS_GROUP_ID_ACK_VERB && v[1] == ALICE_GROUP
        })
        .await;
        let _ = client.close(None).await;
    }

    assert_eq!(
        sidecar_lines(&sidecar_path),
        vec![ALICE_GROUP.to_owned()],
        "a re-declaration on a new connection must not append a duplicate line"
    );
    assert_eq!(sink.stats().distinct, 1);
}
