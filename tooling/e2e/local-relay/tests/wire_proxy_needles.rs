//! End-to-end proof of the needle-declaration channel THROUGH EVERY PROXY
//! BINARY.
//!
//! The unit tests in `src/needles.rs` prove the sinks, and the binary's own
//! `--self-test` (case H) proves the library wiring. Neither answers the
//! question this file exists for: **does the thing a lane actually launches
//! intercept every verb?**
//!
//! That question is not hypothetical. A second binary in the same socket
//! position with its own, shorter verb list would FORWARD the verbs it had not
//! learned — and a forwarded needle declaration is stored by `strfry` and ends
//! up in a relay log a lane uploads. So:
//!
//! * [`PROXY_BINARIES`] is reconciled against `src/bin/` at test time, so a new
//!   proxy binary cannot be added without entering this file's matrix;
//! * no binary may carry a control-verb LITERAL, because the table lives in the
//!   library and a second copy is the defect; and
//! * every entry in `ControlVerb::ALL` is driven through every listed binary,
//!   asserting the sidecar got the declaration, the upstream never saw it, and
//!   the journal never recorded it.

#![cfg(unix)]

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use haven_local_relay::frame::{
    ControlVerb, CANARY_MANIFEST_ACK_VERB, MLS_GROUP_ID_ACK_VERB, NEEDLE_DECL_ACK_VERB,
    SENTINEL_ACK_VERB,
};
use haven_local_relay::needles;
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

/// One binary that can sit between the app and a relay.
struct ProxyBinary {
    /// Its `src/bin/` file name, reconciled against the directory below.
    source: &'static str,
    /// The built executable, resolved by Cargo at compile time.
    exe: &'static str,
}

/// Every proxy binary this crate ships.
///
/// `CARGO_BIN_EXE_*` is compile-time, so a new binary cannot be added to this
/// list without naming it — which is exactly the point:
/// [`every_proxy_binary_under_src_bin_is_listed`] fails until it is here, and
/// the matrix below then drives every control verb through it.
const PROXY_BINARIES: [ProxyBinary; 1] = [ProxyBinary {
    source: "wire_proxy.rs",
    exe: env!("CARGO_BIN_EXE_haven-wire-proxy"),
}];

/// The declared needle. A 64-hex value, like a real pubkey declaration.
const DECL_VALUE: &str = "c0ffee0000000000000000000000000000000000000000000000000000000042";
/// The canary manifest's identifying value.
const MANIFEST_VALUE: &str = "Quiet Wanderer";
/// An MLS group id — 32 bytes, the size MDK mints.
const GROUP_ID: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
/// The sentinel's opaque token.
const SENTINEL_TOKEN: &str = "tok-needles-matrix";

/// The frame a client sends for `verb`, and the value that must not escape.
fn frame_for(verb: ControlVerb) -> (String, &'static str) {
    match verb {
        ControlVerb::Sentinel => (
            format!(r#"["{}","{SENTINEL_TOKEN}"]"#, verb.as_str()),
            SENTINEL_TOKEN,
        ),
        ControlVerb::MlsGroupId => (format!(r#"["{}","{GROUP_ID}"]"#, verb.as_str()), GROUP_ID),
        ControlVerb::NeedleDecl => (
            format!(
                r#"["{}",{{"class":"pubkey","value":"{DECL_VALUE}"}}]"#,
                verb.as_str()
            ),
            DECL_VALUE,
        ),
        ControlVerb::CanaryManifest => (
            format!(
                r#"["{}",{{"role":"alice","petname":"{MANIFEST_VALUE}"}}]"#,
                verb.as_str()
            ),
            MANIFEST_VALUE,
        ),
    }
}

/// The ack verb `verb` is answered with.
const fn ack_verb_for(verb: ControlVerb) -> &'static str {
    match verb {
        ControlVerb::Sentinel => SENTINEL_ACK_VERB,
        ControlVerb::MlsGroupId => MLS_GROUP_ID_ACK_VERB,
        ControlVerb::NeedleDecl => NEEDLE_DECL_ACK_VERB,
        ControlVerb::CanaryManifest => CANARY_MANIFEST_ACK_VERB,
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!("haven-wire-needles-{}-{tag}", unique()));
        std::fs::create_dir_all(&path).expect("temp dir");
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A role unique to one test, so two tests — and two runs — cannot collide in
/// the ONE directory the needle sidecars live in (there is deliberately no
/// environment override that could move them somewhere scratch).
struct Role(String);

impl Role {
    fn new(tag: &str) -> Self {
        Self(format!("ittest-{tag}-{}", unique()))
    }

    fn decl_path(&self) -> PathBuf {
        needles::decl_path(&self.0)
    }

    fn canaries_path(&self) -> PathBuf {
        needles::canaries_path(&self.0)
    }
}

impl Drop for Role {
    fn drop(&mut self) {
        // The files hold declared values; a test must not leave them on the host
        // it ran on.
        let _ = std::fs::remove_file(self.decl_path());
        let _ = std::fs::remove_file(self.canaries_path());
    }
}

fn unique() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    format!("{}-{nanos}", std::process::id())
}

/// An upstream that RECORDS every text message it receives and answers
/// `["ECHO",<message>]`.
///
/// Recording is what makes "the declaration never reached the relay" a direct
/// observation rather than an inference, and the echo gives the barrier that
/// makes the negative deterministic instead of a sleep.
struct EchoUpstream {
    url: String,
    received: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}

impl EchoUpstream {
    async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .await
            .expect("echo bind");
        let addr = listener.local_addr().expect("echo addr");
        let received = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&received);
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let sink = Arc::clone(&sink);
                tokio::spawn(async move {
                    let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else {
                        return;
                    };
                    while let Some(Ok(message)) = ws.next().await {
                        // BOTH kinds are recorded: a forwarded Binary frame
                        // would otherwise be invisible here, and a Binary frame
                        // naming a control verb is one of the shapes the proxy
                        // must refuse. Only Text is echoed — the echo is the
                        // barrier, and the client only ever needs one.
                        let received = match &message {
                            Message::Text(text) => text.as_str().to_owned(),
                            Message::Binary(bytes) => String::from_utf8_lossy(bytes).into_owned(),
                            _ => continue,
                        };
                        sink.lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .push(received.clone());
                        if let Message::Text(_) = message {
                            let echo = Value::Array(vec![
                                Value::String("ECHO".to_owned()),
                                Value::String(received),
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
        Self {
            url: format!("ws://{addr}"),
            received,
            task,
        }
    }

    fn received(&self) -> Vec<String> {
        self.received
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

impl Drop for EchoUpstream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A spawned `haven-wire-proxy`, torn down with SIGTERM so its shutdown summary
/// is on the log when the test reads it.
struct SpawnedProxy {
    child: Child,
    listen: SocketAddr,
    log_path: PathBuf,
    journal_path: PathBuf,
    stopped: bool,
}

impl SpawnedProxy {
    /// Starts `binary` against `upstream`, writing its files under `dir` and its
    /// needle sidecars under the role's real paths.
    async fn start(binary: &ProxyBinary, upstream: &str, dir: &Path, role: &Role) -> Self {
        let log_path = dir.join("proxy.log");
        let journal_path = dir.join("journal.ndjson");
        let log = std::fs::File::create(&log_path).expect("log file");

        // Port 0: the child binds whatever the OS gives it in one step. A port
        // probed here would leave a window for anything on the host to take it.
        let child = Command::new(binary.exe)
            .arg(format!("{}{}", needles::ROLE_ARG_PREFIX, role.0))
            .env("HAVEN_WIRE_PROXY_PORT", "0")
            .env("HAVEN_WIRE_PROXY_UPSTREAM", upstream)
            .env("HAVEN_WIRE_JOURNAL", &journal_path)
            .env("HAVEN_WIRE_MLS_GROUP_ID_FILE", dir.join("ids.mlsgroupid"))
            .stdout(Stdio::null())
            .stderr(Stdio::from(log))
            .spawn()
            .unwrap_or_else(|err| panic!("{} spawns: {err:?}", binary.source));

        // Readiness: the journal line is printed after every route is bound, so
        // the route line above it is present by then.
        let log_text = wait_for(&log_path, "[haven-wire-proxy] journal:").await;
        let listen = parse_listen(&log_text);
        Self {
            child,
            listen,
            log_path,
            journal_path,
            stopped: false,
        }
    }

    async fn connect(&self) -> Client {
        let (client, _) =
            tokio_tungstenite::connect_async(format!("ws://{}", self.listen).as_str())
                .await
                .expect("client connects through the proxy");
        client
    }

    fn journal_text(&self) -> String {
        std::fs::read_to_string(&self.journal_path).unwrap_or_default()
    }

    /// SIGTERM, then the log the shutdown summary landed in.
    fn stop(&mut self) -> String {
        let status = Command::new("kill")
            .args(["-TERM", &self.child.id().to_string()])
            .status()
            .expect("kill runs");
        assert!(status.success(), "SIGTERM could not be delivered");
        let _ = self.child.wait();
        self.stopped = true;
        std::fs::read_to_string(&self.log_path).unwrap_or_default()
    }
}

impl Drop for SpawnedProxy {
    fn drop(&mut self) {
        if !self.stopped {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// Polls `path` until it contains `marker`. A readiness poll, not a timing
/// assertion: nothing is measured, and the bound only stops the test hanging.
async fn wait_for(path: &Path, marker: &str) -> String {
    for _ in 0..400 {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        if text.contains(marker) {
            return text;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("proxy never printed '{marker}'");
}

/// The bound listen address out of the proxy's own readiness line
/// (`[haven-wire-proxy] ws://127.0.0.1:PORT -> ws://…`).
fn parse_listen(log_text: &str) -> SocketAddr {
    log_text
        .lines()
        .find_map(|line| {
            let rest = line.strip_prefix("[haven-wire-proxy] ws://")?;
            let addr = rest.split_whitespace().next()?;
            addr.parse().ok()
        })
        .unwrap_or_else(|| panic!("no route line in the proxy log:\n{log_text}"))
}

async fn send(client: &mut Client, text: &str) {
    client
        .send(Message::Text(text.into()))
        .await
        .expect("client send");
}

async fn send_binary(client: &mut Client, bytes: &[u8]) {
    client
        .send(Message::Binary(bytes.to_vec().into()))
        .await
        .expect("client send (binary)");
}

/// Reads until `predicate` matches, returning everything seen on the way.
async fn recv_collecting(
    client: &mut Client,
    what: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Vec<String> {
    let mut seen = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
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

fn lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect()
}

// ---------------------------------------------------------------------------
// The matrix
// ---------------------------------------------------------------------------

/// (b) Nothing the client declared reached the RELAY SOCKET.
///
/// Asserted over what the upstream RECORDED, which makes it a direct
/// observation; the barrier before it is what makes the negative deterministic.
fn assert_nothing_escaped(source: &str, received: &[String], values: &[&str]) {
    assert!(
        received.iter().any(|m| m.contains("\"after\"")),
        "{source}: the upstream recorded nothing, so its silence proves nothing"
    );
    for message in received {
        for verb in ControlVerb::ALL {
            assert!(
                !message.contains(verb.as_str()),
                "{source}: {} reached the relay socket. A control verb a relay stores lands in a \
                 log the lane uploads.",
                verb.as_str()
            );
        }
        for value in values {
            assert!(
                !message.contains(value),
                "{source}: a declared value reached the relay socket"
            );
        }
    }
}

/// (c) The journal recorded the traffic and none of the declarations.
///
/// The sentinel is the one intended exception — it is a marker IN the recording
/// — so it is deliberately not in the list below.
fn assert_journal_is_clean(source: &str, journal: &str) {
    assert!(
        journal.contains("\"after\""),
        "{source}: the journal recorded nothing, so its silence proves nothing"
    );
    for verb in [
        ControlVerb::MlsGroupId,
        ControlVerb::NeedleDecl,
        ControlVerb::CanaryManifest,
    ] {
        let (_, value) = frame_for(verb);
        assert!(
            !journal.contains(verb.as_str()) && !journal.contains(value),
            "{source}: {} reached the JOURNAL, which the scanner reads as a sink — the run would \
             report a leak it made itself",
            verb.as_str()
        );
    }
}

/// (a) Both sidecars hold exactly one line, in the format `haven-logscan seal`
/// and `check-wire-canaries.dart` parse, at the path derived from the role.
fn assert_sidecars(source: &str, role: &Role) {
    assert_eq!(
        lines(&role.decl_path()),
        vec![format!(
            r#"{{"class":"pubkey","role":"{}","seq":0,"value":"{DECL_VALUE}"}}"#,
            role.0
        )],
        "{source}: the declaration sidecar must hold exactly the declared object plus role and seq"
    );
    assert_eq!(
        lines(&role.canaries_path()),
        vec![format!(
            r#"{{"petname":"{MANIFEST_VALUE}","role":"alice"}}"#
        )],
        "{source}: the canary sidecar must hold one manifest object per line"
    );
}

/// Every control verb, driven through every proxy binary, asserting the three
/// properties the channel's privacy rests on.
#[tokio::test(flavor = "multi_thread")]
async fn every_proxy_binary_intercepts_every_control_verb() {
    for binary in &PROXY_BINARIES {
        let dir = TempDir::new("matrix");
        let role = Role::new("matrix");
        let upstream = EchoUpstream::start().await;
        let mut proxy = SpawnedProxy::start(binary, &upstream.url, &dir.0, &role).await;
        let mut client = proxy.connect().await;

        // Prove the upstream really is receiving, or "the declaration did not
        // arrive" would be true of everything and prove nothing.
        send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await;
        recv_collecting(&mut client, "the echo of the pre-declaration REQ", |v| {
            v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("before"))
        })
        .await;

        let mut values = Vec::new();
        for verb in ControlVerb::ALL {
            let (frame, value) = frame_for(verb);
            values.push(value);
            send(&mut client, &frame).await;
            let ack_verb = ack_verb_for(verb);
            recv_collecting(
                &mut client,
                &format!("the ack for {} from {}", verb.as_str(), binary.source),
                |v| v[0] == ack_verb,
            )
            .await;
        }

        // THE BARRIER: the upstream answers in order on one connection, so once
        // the echo of a message sent after every declaration comes back, a
        // forwarded declaration would already have arrived.
        send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await;
        recv_collecting(&mut client, "the echo of the post-declaration REQ", |v| {
            v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("after"))
        })
        .await;

        // (b) THE DOWNSTREAM RELAY SOCKET NEVER RECEIVED THE FRAME.
        assert_nothing_escaped(binary.source, &upstream.received(), &values);
        // (c) THE JOURNAL NEVER RECORDED THE PAYLOAD.
        assert_journal_is_clean(binary.source, &proxy.journal_text());
        // (a) THE SIDECAR GOT EXACTLY THE LINE, at the path derived from the
        // role and from nothing else.
        assert_sidecars(binary.source, &role);

        // ...and the shutdown summary reports the channel by COUNT, never by
        // value — it is tailed into the step log by stop-wire-proxy.sh.
        let log = proxy.stop();
        assert!(
            log.contains("needle sidecar: 1 declaration(s) recorded, 0 refused, 0 lost"),
            "{}: the shutdown summary must state the needle count:\n{log}",
            binary.source
        );
        assert!(
            log.contains("canary sidecar: 1 manifest(s) recorded, 0 repeat(s), 0 refused, 0 lost"),
            "{}: the shutdown summary must state the manifest outcome:\n{log}",
            binary.source
        );
        for value in &values {
            assert!(
                !log.contains(value),
                "{}: the proxy log carried a declared value, and the lane uploads that log",
                binary.source
            );
        }
    }
}

/// A `HAVEN_*` verb outside the shared table ends the connection in every proxy
/// binary, instead of being forwarded.
#[tokio::test(flavor = "multi_thread")]
async fn an_unknown_control_verb_terminates_the_connection_in_every_proxy_binary() {
    const PAYLOAD: &str = "never-forwarded-by-any-binary";

    for binary in &PROXY_BINARIES {
        let dir = TempDir::new("unknown");
        let role = Role::new("unknown");
        let upstream = EchoUpstream::start().await;
        let proxy = SpawnedProxy::start(binary, &upstream.url, &dir.0, &role).await;
        let mut client = proxy.connect().await;

        send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await;
        recv_collecting(&mut client, "the echo of the pre-verb REQ", |v| {
            v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("before"))
        })
        .await;

        send(
            &mut client,
            &format!(r#"["HAVEN_WIRE_CHAOS",{{"value":"{PAYLOAD}"}}]"#),
        )
        .await;

        // The connection must END. Reading to the end of the stream is the
        // deterministic form of that assertion.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(
                !remaining.is_zero(),
                "{}: the connection stayed open after an unknown control verb",
                binary.source
            );
            let next = tokio::time::timeout(remaining, client.next())
                .await
                .unwrap_or_else(|_| {
                    panic!(
                        "{}: the connection stayed open after an unknown control verb",
                        binary.source
                    )
                });
            match next {
                None | Some(Err(_)) => break,
                Some(Ok(_)) => {}
            }
        }

        assert!(
            upstream.received().iter().all(|m| !m.contains(PAYLOAD)),
            "{}: an unknown control verb was FORWARDED; a future verb's payload would reach the \
             relay and every log its operator keeps",
            binary.source
        );
        let journal = proxy.journal_text();
        assert!(
            !journal.contains(PAYLOAD) && !journal.contains("HAVEN_WIRE_CHAOS"),
            "{}: an unknown control verb reached the journal",
            binary.source
        );
        assert!(
            journal.contains("unknown control verb"),
            "{}: the termination left no conn_error record, so a lane would see a connection that \
             simply stopped:\n{journal}",
            binary.source
        );
    }
}

/// Every shape a MIS-SHAPED control frame arrives in is refused, with the
/// connection left OPEN — never forwarded, never journalled, never acked.
///
/// This is the byte-level gate's other half. Interception was once keyed on the
/// PARSED form, so truncated JSON, a JSON object and a Binary frame all carried
/// their payload to the relay AND into the journal. The MLS verb has that test
/// (`wire_proxy_mls_group_id.rs`); the needle verbs carry values of every class
/// the scanner knows, so they need it more.
#[tokio::test(flavor = "multi_thread")]
async fn a_misshaped_control_frame_is_refused_with_the_connection_left_open() {
    const VALUE: &str = "never-relayed-misshaped-0001";

    for binary in &PROXY_BINARIES {
        let dir = TempDir::new("misshaped");
        let role = Role::new("misshaped");
        let upstream = EchoUpstream::start().await;
        let proxy = SpawnedProxy::start(binary, &upstream.url, &dir.0, &role).await;
        let mut client = proxy.connect().await;

        // Prove the upstream really is receiving, or every absence below would
        // be true of everything and prove nothing.
        send(&mut client, r#"["REQ","before",{"kinds":[1]}]"#).await;
        recv_collecting(&mut client, "the echo of the pre-declaration REQ", |v| {
            v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("before"))
        })
        .await;

        for verb in [ControlVerb::NeedleDecl, ControlVerb::CanaryManifest] {
            let token = verb.as_str();
            // Truncated: the array never closes, so serde refuses it.
            send(&mut client, &format!(r#"["{token}",{{"value":"{VALUE}"#)).await;
            // A JSON object rather than an array: parses, wrong shape.
            send(
                &mut client,
                &format!(r#"{{"verb":"{token}","value":"{VALUE}"}}"#),
            )
            .await;
            // Not text at all.
            send_binary(
                &mut client,
                format!(r#"["{token}",{{"value":"{VALUE}"}}]"#).as_bytes(),
            )
            .await;
        }

        // THE BARRIER, which is also the proof the connection SURVIVED: a
        // mis-shaped control frame is refused, not fatal — only an unrecognised
        // verb ends the connection.
        send(&mut client, r#"["REQ","after",{"kinds":[1]}]"#).await;
        let seen = recv_collecting(&mut client, "the echo of the post-declaration REQ", |v| {
            v[0] == "ECHO" && v[1].as_str().is_some_and(|t| t.contains("after"))
        })
        .await;
        for message in &seen {
            assert!(
                !message.contains("_ACK"),
                "{}: a mis-shaped frame was ACKED; an ack has to mean the host holds the value",
                binary.source
            );
        }

        let received = upstream.received();
        assert!(
            received.iter().any(|m| m.contains("\"after\"")),
            "{}: the upstream recorded nothing, so its silence proves nothing",
            binary.source
        );
        for message in &received {
            assert!(
                !message.contains(VALUE),
                "{}: a mis-shaped control frame carried its payload to the relay: the Rule-4 / \
                 Rule-15 guarantee would be a property of the PARSER rather than of the verb",
                binary.source
            );
        }
        let journal = proxy.journal_text();
        assert!(
            journal.contains("\"after\""),
            "{}: the journal recorded nothing, so its silence proves nothing",
            binary.source
        );
        assert!(
            !journal.contains(VALUE),
            "{}: a mis-shaped control frame reached the journal — raw_preview keeps 200 chars, \
             which is the whole declaration",
            binary.source
        );
        for path in [role.decl_path(), role.canaries_path()] {
            assert!(
                !path.exists(),
                "{}: a refused frame must not even create a sidecar: {path:?}",
                binary.source
            );
        }
    }
}

// ---------------------------------------------------------------------------
// The reconciliation that keeps the matrix honest
// ---------------------------------------------------------------------------

/// Every binary under `src/bin/` that can proxy app traffic is in
/// [`PROXY_BINARIES`], and nothing else is.
///
/// Without this, adding `wire_chaos.rs` would add a binary in the app's socket
/// position that no test above ever drives — the exact hole B4 names.
#[test]
fn every_proxy_binary_under_src_bin_is_listed() {
    let bin_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/bin");
    let mut proxies = BTreeSet::new();
    let mut others = BTreeSet::new();
    for entry in std::fs::read_dir(&bin_dir).expect("src/bin is readable") {
        let path = entry.expect("a dir entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .expect("a file name")
            .to_owned();
        let source = std::fs::read_to_string(&path).expect("a readable source file");
        // "Proxies app traffic" means it starts the recorder that owns the
        // listening socket — the only way into the app's relay path using this
        // library.
        if source.contains("Proxy::start") {
            proxies.insert(name);
        } else {
            others.insert(name);
        }
    }

    let listed: BTreeSet<String> = PROXY_BINARIES
        .iter()
        .map(|b| (*b.source).to_owned())
        .collect();
    assert_eq!(
        proxies, listed,
        "every binary that starts the proxy must be driven by this file's matrix; listed={listed:?}"
    );
    assert!(
        others.is_disjoint(&listed),
        "a binary that does not proxy traffic is listed as one: {others:?}"
    );
}

/// No binary carries a control-verb literal: the table is the library's.
///
/// A second copy of the list is how a binary ends up intercepting three verbs
/// out of four, which is indistinguishable from working until the fourth one
/// reaches a relay.
#[test]
fn no_proxy_binary_declares_its_own_control_verb() {
    let bin_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/bin");
    for entry in std::fs::read_dir(&bin_dir).expect("src/bin is readable") {
        let path = entry.expect("a dir entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("a readable source file");
        for (number, line) in source.lines().enumerate() {
            // Prose may name a verb; a string LITERAL is a second table.
            let code = line.split("//").next().unwrap_or_default();
            assert!(
                !code.contains("\"HAVEN_"),
                "{}:{}: a control-verb literal in a binary is a second verb table. Use \
                 haven_local_relay::frame::ControlVerb.",
                path.display(),
                number + 1
            );
        }
    }
}
