//! The fail-open NDJSON wire journal.
//!
//! # Fail-open is a property of the TYPE, not of the call sites
//!
//! Every recording entry point returns `u64` — the assigned `wire_seq` — and
//! has no error channel at all. There is nothing for a caller to ignore,
//! nothing for a `?` to propagate, and no way for a later edit to accidentally
//! make a recording failure abort a connection. Every failure mode (unwritable
//! path, disk full, a panicking sink) latches a degraded flag, is reported
//! once on stderr, and the proxy keeps forwarding traffic.
//!
//! `scripts/ci/check_wire_proxy_test_only.sh` pins those signatures, and pins
//! that this file's non-test code contains no `unwrap`, `expect` or `panic!`.
//!
//! # Ordering
//!
//! The sequence number is allocated UNDER the same lock as the write, so a
//! journal's line order is identical to its `wire_seq` order across every
//! connection and every route. A consumer may stream the file and rely on
//! that, instead of buffering and sorting. Contention is irrelevant at E2E
//! message rates.
//!
//! # Record types
//!
//! Every line carries a `type`. Three values exist:
//!
//! * `"frame"` — one Text/Binary WebSocket message. Carries the contract
//!   fields plus `relay_url`.
//! * `"conn_open"` — one per accepted client connection, always ordered
//!   BEFORE that connection's first frame.
//! * `"conn_error"` — the connection could not be completed end to end. This
//!   covers a failed handshake, a failed dial, a mid-stream read failure, and
//!   the one case where the journal has to retract a claim it already made:
//!   frames that were recorded and then could not be delivered, which carry an
//!   extra `discarded` count (see [`WireJournal::record_discarded`]).
//!
//! Three, and deliberately only three: every consumer validates `type` against
//! that closed set, so a fourth record type would make each of them report a
//! perfectly good journal as UNUSABLE.
//!
//! A consumer that only wants traffic filters on `type == "frame"`; the
//! `frame` key is present (possibly `null`) on exactly those lines, so
//! `"frame" in line` is an equivalent discriminator.

use std::fs::OpenOptions;
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::{Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;

use crate::frame::Observation;

/// `type` value for a traffic line.
pub const TYPE_FRAME: &str = "frame";
/// `type` value for a connection-open record.
pub const TYPE_CONN_OPEN: &str = "conn_open";
/// `type` value for a connection-failure record.
pub const TYPE_CONN_ERROR: &str = "conn_error";

/// Direction of an observed message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dir {
    /// Client → relay.
    ClientToRelay,
    /// Relay → client.
    RelayToClient,
}

impl Dir {
    /// The on-the-wire token written to the journal.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ClientToRelay => "c2r",
            Self::RelayToClient => "r2c",
        }
    }
}

/// Identifies the endpoint a connection is proxied to.
///
/// `conn_id` alone is opaque, so an endpoint-level assertion ("no event ever
/// reached an unconfigured relay") could not be written against it. Both
/// halves are recorded: `upstream` is where the bytes actually went, and
/// `listen` is the proxy address the client dialled — which is how a lane
/// correlates a connection back to the relay entry it configured in the app.
#[derive(Debug, Clone)]
pub struct Endpoint {
    /// Upstream relay URL the proxy forwards this connection to.
    pub upstream: String,
    /// `host:port` of the proxy listener that accepted the connection.
    pub listen: String,
}

/// Why recording stopped. Kept as a small enum rather than an OS message so
/// the proxy's own logs stay presence-only (Security Rules 6 and 8: never log
/// key material, never interpolate a raw error).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Degraded {
    /// The journal path could not be opened for append.
    OpenFailed,
    /// A write to the journal failed.
    WriteFailed,
    /// Serialising a line failed.
    EncodeFailed,
    /// The recorder panicked — in the sink or in encoding a line. One variant
    /// for both because a panic caught by one `catch_unwind` cannot be
    /// attributed to either half after the fact.
    SinkPanicked,
    /// No journal was configured at all.
    NotConfigured,
}

impl Degraded {
    const fn as_str(self) -> &'static str {
        match self {
            Self::OpenFailed => "journal could not be opened",
            Self::WriteFailed => "journal write failed",
            Self::EncodeFailed => "journal line could not be encoded",
            Self::SinkPanicked => "journal recorder panicked",
            Self::NotConfigured => "no journal configured",
        }
    }
}

/// A snapshot of the journal's health, for the shutdown summary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JournalStats {
    /// Sequence numbers handed out (== records observed).
    pub observed: u64,
    /// Lines actually written to the journal.
    pub written: u64,
    /// `Some(reason)` once recording has failed.
    pub degraded: Option<Degraded>,
}

/// Serialised shape of one traffic line. Field ORDER is the declaration order
/// (serde derive preserves it), which keeps the file readable by eye; every
/// consumer parses it as JSON, where order is irrelevant.
#[derive(Serialize)]
struct FrameLine<'a> {
    wire_seq: u64,
    #[serde(rename = "type")]
    record_type: &'static str,
    conn_id: &'a str,
    ts_ms: u64,
    dir: &'static str,
    relay_url: &'a str,
    listen: &'a str,
    /// `null` for a message that was not structurally a Nostr frame. Never
    /// omitted: a consumer must be able to tell "unparseable" from "absent".
    frame: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    raw_preview: Option<&'a str>,
    raw_len: usize,
}

/// Serialised shape of a connection-lifecycle record.
///
/// No `dir` and no `frame`, on purpose: `"frame" in line` and `type == "frame"`
/// have to stay equivalent discriminators, and consumers rely on a lifecycle
/// record carrying no direction.
#[derive(Serialize)]
struct ConnLine<'a> {
    wire_seq: u64,
    #[serde(rename = "type")]
    record_type: &'static str,
    conn_id: &'a str,
    ts_ms: u64,
    relay_url: &'a str,
    listen: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'static str>,
    /// Present only on a discard record: how many journalled frames on this
    /// connection, in the direction named by `reason`, never left the proxy.
    #[serde(skip_serializing_if = "Option::is_none")]
    discarded: Option<u64>,
}

type Sink = Box<dyn Write + Send>;

struct Inner {
    next_seq: u64,
    written: u64,
    sink: Option<Sink>,
    degraded: Option<Degraded>,
}

/// Append-only NDJSON journal shared by every proxied connection.
pub struct WireJournal {
    inner: Mutex<Inner>,
}

impl WireJournal {
    /// Opens `path` for append.
    ///
    /// Never fails: an unopenable path yields a journal that is already
    /// degraded and records nothing, because a lane must still be able to run
    /// when its instrument cannot. The caller is told which happened via
    /// [`WireJournal::stats`].
    #[must_use]
    pub fn open(path: &Path) -> Self {
        match OpenOptions::new().create(true).append(true).open(path) {
            Ok(file) => Self::with_sink(Box::new(file)),
            Err(err) => {
                eprintln!(
                    "[haven-wire-proxy] WARNING: journal unavailable ({:?}); \
                     traffic will flow UNRECORDED. The oracle that reads this \
                     journal must fail closed on the empty/absent file.",
                    err.kind()
                );
                Self::degraded(Degraded::OpenFailed)
            }
        }
    }

    /// A journal backed by an arbitrary sink. Used by tests to inject a sink
    /// that fails or panics.
    #[must_use]
    pub fn with_sink(sink: Sink) -> Self {
        Self {
            inner: Mutex::new(Inner {
                next_seq: 0,
                written: 0,
                sink: Some(sink),
                degraded: None,
            }),
        }
    }

    /// A journal that records nothing.
    #[must_use]
    pub fn degraded(reason: Degraded) -> Self {
        Self {
            inner: Mutex::new(Inner {
                next_seq: 0,
                written: 0,
                sink: None,
                degraded: Some(reason),
            }),
        }
    }

    /// Records one observed message and returns its `wire_seq`.
    ///
    /// Infallible by construction — see the module docs. The sequence number
    /// is allocated even when the write cannot happen, so a degraded journal
    /// still answers a sentinel with a number, and the resulting hole is
    /// exactly what makes a consumer's fail-closed check fire.
    pub fn record(
        &self,
        conn_id: &str,
        endpoint: &Endpoint,
        dir: Dir,
        ts_ms: u64,
        obs: &Observation,
    ) -> u64 {
        self.emit(|wire_seq| FrameLine {
            wire_seq,
            record_type: TYPE_FRAME,
            conn_id,
            ts_ms,
            dir: dir.as_str(),
            relay_url: &endpoint.upstream,
            listen: &endpoint.listen,
            frame: obs.frame.as_ref(),
            raw_preview: obs.raw_preview.as_deref(),
            raw_len: obs.raw_len,
        })
    }

    /// Records that a client connection was accepted, binding its `conn_id`
    /// to an endpoint. Always ordered before that connection's first frame.
    pub fn record_conn_open(&self, conn_id: &str, endpoint: &Endpoint, ts_ms: u64) -> u64 {
        self.emit(|wire_seq| ConnLine {
            wire_seq,
            record_type: TYPE_CONN_OPEN,
            conn_id,
            ts_ms,
            relay_url: &endpoint.upstream,
            listen: &endpoint.listen,
            reason: None,
            discarded: None,
        })
    }

    /// Records that a connection could not be completed end to end.
    ///
    /// `reason` is a fixed label, never a transport error's own message: a
    /// dial failure's text can carry remote-authored content.
    pub fn record_conn_error(
        &self,
        conn_id: &str,
        endpoint: &Endpoint,
        ts_ms: u64,
        reason: &'static str,
    ) -> u64 {
        self.emit(|wire_seq| ConnLine {
            wire_seq,
            record_type: TYPE_CONN_ERROR,
            conn_id,
            ts_ms,
            relay_url: &endpoint.upstream,
            listen: &endpoint.listen,
            reason: Some(reason),
            discarded: None,
        })
    }

    /// Retracts a claim: `discarded` frames on this connection were recorded
    /// as sent and then did not reach `relay_url`.
    ///
    /// A traffic line is written BEFORE the message is handed to its socket,
    /// so every `frame` line asserts a delivery. When a teardown cannot flush
    /// what it holds, that assertion is false for the LAST `discarded`
    /// journalled lines of this connection in the direction `reason` names —
    /// the queue is FIFO and the recorder writes in the same order, so the
    /// retraction is precise rather than a blanket "distrust this connection".
    ///
    /// Written as a `conn_error` because the three record types are a closed
    /// set every consumer validates against.
    pub fn record_discarded(
        &self,
        conn_id: &str,
        endpoint: &Endpoint,
        ts_ms: u64,
        reason: &'static str,
        discarded: u64,
    ) -> u64 {
        self.emit(|wire_seq| ConnLine {
            wire_seq,
            record_type: TYPE_CONN_ERROR,
            conn_id,
            ts_ms,
            relay_url: &endpoint.upstream,
            listen: &endpoint.listen,
            reason: Some(reason),
            discarded: Some(discarded),
        })
    }

    /// The single write path. Allocates the sequence number and writes the
    /// line under one lock, so file order and `wire_seq` order agree.
    fn emit<T: Serialize, F: FnOnce(u64) -> T>(&self, build: F) -> u64 {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);

        let seq = inner.next_seq;
        inner.next_seq = inner.next_seq.wrapping_add(1);

        if inner.sink.is_none() {
            return seq;
        }

        // ENCODING AND WRITING BOTH LIVE INSIDE `catch_unwind`.
        //
        // A `Serialize` impl can panic just as a sink can, and this runs while
        // holding the lock: a panic escaping here would unwind through the
        // connection pump and take the proxied traffic down with it, which is
        // precisely the "instrument breaks the product" outcome fail-open
        // exists to prevent. Leaving the encode outside made the containment
        // claim in the module docs, in docs/WIRE_JOURNAL.md and in
        // check_wire_proxy_test_only.sh's header true only of the write half.
        //
        // Line and newline are built into ONE buffer and handed to a single
        // `write_all`. That is the smallest unit this can offer, but it is NOT
        // an atomicity guarantee: `write_all` loops over partial writes, so a
        // consumer tailing the file concurrently can still read a line without
        // its terminator. Consumers must treat an unterminated final line as
        // truncation — which is what they do, and which is why a torn line is
        // reported rather than skipped.
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            let mut encoded =
                serde_json::to_string(&build(seq)).map_err(|_| Degraded::EncodeFailed)?;
            encoded.push('\n');
            inner
                .sink
                .as_mut()
                .map_or(Err(Degraded::WriteFailed), |sink| {
                    sink.write_all(encoded.as_bytes())
                        .and_then(|()| sink.flush())
                        .map_err(|_| Degraded::WriteFailed)
                })
        }));

        match outcome {
            Ok(Ok(())) => inner.written = inner.written.wrapping_add(1),
            Ok(Err(reason)) => degrade(&mut inner, reason),
            Err(_) => degrade(&mut inner, Degraded::SinkPanicked),
        }

        seq
    }

    /// Current health snapshot.
    #[must_use]
    pub fn stats(&self) -> JournalStats {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        JournalStats {
            observed: inner.next_seq,
            written: inner.written,
            degraded: inner.degraded,
        }
    }

    /// `true` once recording has stopped for any reason.
    #[must_use]
    pub fn is_degraded(&self) -> bool {
        self.stats().degraded.is_some()
    }
}

/// Latches the degraded flag, drops the sink, and reports ONCE.
fn degrade(inner: &mut Inner, reason: Degraded) {
    inner.sink = None;
    if inner.degraded.is_none() {
        inner.degraded = Some(reason);
        eprintln!(
            "[haven-wire-proxy] WARNING: recording stopped ({}) after {} line(s); \
             traffic continues UNRECORDED. The journal is now truncated — an \
             oracle reading it must fail closed.",
            reason.as_str(),
            inner.written
        );
    }
}

/// Proxy-side wall clock in milliseconds. A clock before the Unix epoch
/// yields 0 rather than aborting; the journal's ordering guarantee comes from
/// `wire_seq`, never from `ts_ms`.
#[must_use]
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::{classify_binary, classify_text};
    use std::io;
    use std::sync::{Arc, Mutex as StdMutex};

    fn endpoint() -> Endpoint {
        Endpoint {
            upstream: "ws://127.0.0.1:7777".to_owned(),
            listen: "127.0.0.1:7788".to_owned(),
        }
    }

    /// A sink that captures everything written to it.
    #[derive(Clone, Default)]
    struct Capture(Arc<StdMutex<Vec<u8>>>);

    impl Capture {
        fn text(&self) -> String {
            let guard = self.0.lock().expect("capture lock");
            String::from_utf8(guard.clone()).expect("journal is UTF-8")
        }

        fn lines(&self) -> Vec<Value> {
            self.text()
                .lines()
                .map(|l| serde_json::from_str(l).expect("every line is JSON"))
                .collect()
        }

        fn frames(&self) -> Vec<Value> {
            self.lines()
                .into_iter()
                .filter(|l| l["type"] == TYPE_FRAME)
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

    /// A sink whose every write fails — the disk-full / unwritable case.
    struct AlwaysFails;

    impl Write for AlwaysFails {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::StorageFull, "no space"))
        }

        fn flush(&mut self) -> io::Result<()> {
            Err(io::Error::new(io::ErrorKind::StorageFull, "no space"))
        }
    }

    /// A sink that PANICS — the "a recorder panic must not break traffic" case.
    struct Panics;

    impl Write for Panics {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            panic!("sink exploded");
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// A sink whose writes count how many calls one line took.
    #[derive(Clone, Default)]
    struct PartialWrites {
        calls: Arc<StdMutex<usize>>,
    }

    impl Write for PartialWrites {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            {
                let mut calls = self.calls.lock().expect("calls lock");
                *calls += 1;
            }
            // One byte at a time: a legal `Write` implementation, and exactly
            // what a socket or a filling disk does.
            Ok(buf.len().min(1))
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// A value whose `Serialize` panics — the ENCODE half of "the recorder
    /// panicked", as opposed to the sink half.
    struct PanicsOnSerialize;

    impl Serialize for PanicsOnSerialize {
        fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
            panic!("encoder exploded");
        }
    }

    fn record_text(journal: &WireJournal, conn: &str, dir: Dir, text: &str) -> u64 {
        journal.record(
            conn,
            &endpoint(),
            dir,
            1_785_886_144_123,
            &classify_text(text),
        )
    }

    #[test]
    fn writes_the_contract_shape_for_a_parsed_frame() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        let seq = record_text(
            &journal,
            "c3",
            Dir::ClientToRelay,
            r#"["EVENT",{"kind":445}]"#,
        );

        assert_eq!(seq, 0, "wire_seq starts at 0");
        let lines = capture.lines();
        assert_eq!(lines.len(), 1);
        let line = &lines[0];
        assert_eq!(line["wire_seq"], 0);
        assert_eq!(line["type"], TYPE_FRAME);
        assert_eq!(line["conn_id"], "c3");
        assert_eq!(line["ts_ms"], 1_785_886_144_123_u64);
        assert_eq!(line["dir"], "c2r");
        assert_eq!(line["frame"][0], "EVENT");
        assert_eq!(line["raw_len"], r#"["EVENT",{"kind":445}]"#.len());
        assert!(
            line.get("raw_preview").is_none(),
            "a parsed frame carries no preview"
        );
    }

    // C5.6 (publish-target containment) is a statement about ENDPOINTS, so
    // every traffic line has to name one without a join.
    #[test]
    fn every_traffic_line_names_its_relay_endpoint() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        record_text(&journal, "c0", Dir::ClientToRelay, r#"["EVENT",{}]"#);
        record_text(&journal, "c0", Dir::RelayToClient, r#"["OK","a",true,""]"#);

        for line in capture.frames() {
            assert_eq!(line["relay_url"], "ws://127.0.0.1:7777");
            assert_eq!(line["listen"], "127.0.0.1:7788");
        }
    }

    #[test]
    fn a_conn_open_record_binds_conn_id_to_an_endpoint() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        let seq = journal.record_conn_open("c7", &endpoint(), 42);
        record_text(&journal, "c7", Dir::ClientToRelay, r#"["REQ","s",{}]"#);

        let lines = capture.lines();
        assert_eq!(seq, 0);
        assert_eq!(lines[0]["type"], TYPE_CONN_OPEN);
        assert_eq!(lines[0]["conn_id"], "c7");
        assert_eq!(lines[0]["relay_url"], "ws://127.0.0.1:7777");
        assert_eq!(lines[0]["listen"], "127.0.0.1:7788");
        assert!(
            lines[0].get("frame").is_none(),
            "a lifecycle record carries no frame key, so `\"frame\" in line` \
             discriminates traffic exactly like `type == \"frame\"`"
        );
        assert!(
            lines[0].get("dir").is_none(),
            "a lifecycle record carries no dir, so a consumer switching on dir \
             must filter on type first"
        );
        assert!(
            lines[0]["wire_seq"].as_u64() < lines[1]["wire_seq"].as_u64(),
            "conn_open must precede the connection's first frame"
        );
    }

    // A connection that carries ZERO frames is invisible in a frame-only
    // journal — and "the app dialled an endpoint and sent nothing" is itself a
    // containment finding.
    #[test]
    fn a_failed_connection_still_leaves_an_endpoint_record() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        journal.record_conn_open("c0", &endpoint(), 1);
        journal.record_conn_error("c0", &endpoint(), 2, "upstream connect failed");

        let lines = capture.lines();
        assert_eq!(lines[1]["type"], TYPE_CONN_ERROR);
        assert_eq!(lines[1]["reason"], "upstream connect failed");
        assert_eq!(lines[1]["relay_url"], "ws://127.0.0.1:7777");
    }

    // A traffic line is written BEFORE the message reaches its socket, so it
    // CLAIMS a delivery. When that claim turns out false the journal has to
    // retract it — and it has to do so within the three record types every
    // consumer validates against, or a perfectly good journal reads as
    // UNUSABLE.
    #[test]
    fn a_discard_record_retracts_a_delivery_claim_without_a_new_record_type() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        record_text(&journal, "c0", Dir::ClientToRelay, r#"["EVENT",{}]"#);
        journal.record_discarded("c0", &endpoint(), 9, "c2r frames discarded", 3);

        let lines = capture.lines();
        let retraction = &lines[1];
        assert_eq!(
            retraction["type"], TYPE_CONN_ERROR,
            "a fourth record type would make every consumer reject the journal"
        );
        assert_eq!(retraction["reason"], "c2r frames discarded");
        assert_eq!(retraction["discarded"], 3);
        assert_eq!(retraction["conn_id"], "c0");
        assert_eq!(retraction["relay_url"], "ws://127.0.0.1:7777");
        assert!(
            retraction.get("frame").is_none() && retraction.get("dir").is_none(),
            "a lifecycle record carries no frame and no dir, so `\"frame\" in \
             line` stays equivalent to `type == \"frame\"`"
        );
        assert!(
            lines[0]["wire_seq"].as_u64() < retraction["wire_seq"].as_u64(),
            "the retraction is ordered after the lines it retracts"
        );
    }

    // Every other lifecycle record must stay free of the count, or a consumer
    // cannot tell a retraction from a dial failure.
    #[test]
    fn only_a_discard_record_carries_a_discarded_count() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        journal.record_conn_open("c0", &endpoint(), 1);
        journal.record_conn_error("c0", &endpoint(), 2, "upstream connect failed");

        for line in capture.lines() {
            assert!(
                line.get("discarded").is_none(),
                "an ordinary lifecycle record must not carry a discard count: {line}"
            );
        }
    }

    #[test]
    fn r2c_direction_is_written_verbatim() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        record_text(&journal, "c0", Dir::RelayToClient, r#"["EOSE","s"]"#);
        assert_eq!(capture.lines()[0]["dir"], "r2c");
    }

    #[test]
    fn an_unparseable_frame_is_recorded_as_null_with_a_preview() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        record_text(&journal, "c0", Dir::ClientToRelay, "<<garbage>>");

        let line = &capture.lines()[0];
        assert!(line["frame"].is_null(), "frame must be explicit null");
        assert_eq!(line["raw_preview"], "<<garbage>>");
        assert_eq!(line["raw_len"], 11);
    }

    #[test]
    fn a_binary_message_is_recorded_rather_than_dropped() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        journal.record(
            "c0",
            &endpoint(),
            Dir::ClientToRelay,
            7,
            &classify_binary(&[1, 2, 3]),
        );
        let line = &capture.lines()[0];
        assert!(line["frame"].is_null());
        assert_eq!(line["raw_len"], 3);
    }

    #[test]
    fn wire_seq_is_monotonic_across_connections() {
        let capture = Capture::default();
        let journal = WireJournal::with_sink(Box::new(capture.clone()));
        for (conn, dir) in [
            ("c0", Dir::ClientToRelay),
            ("c1", Dir::ClientToRelay),
            ("c0", Dir::RelayToClient),
            ("c1", Dir::RelayToClient),
            ("c2", Dir::ClientToRelay),
        ] {
            record_text(&journal, conn, dir, r#"["EOSE","s"]"#);
        }

        let lines = capture.lines();
        let seqs: Vec<u64> = lines
            .iter()
            .map(|l| l["wire_seq"].as_u64().expect("wire_seq is an int"))
            .collect();
        assert_eq!(seqs, vec![0, 1, 2, 3, 4]);
        // FILE order equals SEQ order — the allocation happens under the write
        // lock, so a consumer can stream instead of buffering and sorting.
        assert!(seqs.windows(2).all(|w| w[0] < w[1]));

        let conns: Vec<&str> = lines
            .iter()
            .map(|l| l["conn_id"].as_str().expect("conn_id is a string"))
            .collect();
        assert_eq!(conns, vec!["c0", "c1", "c0", "c1", "c2"]);
    }

    #[test]
    fn concurrent_recorders_never_reuse_a_wire_seq() {
        let capture = Capture::default();
        let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
        let mut handles = Vec::new();
        for conn in 0..8 {
            let journal = Arc::clone(&journal);
            handles.push(std::thread::spawn(move || {
                for _ in 0..50 {
                    record_text(
                        &journal,
                        &format!("c{conn}"),
                        Dir::ClientToRelay,
                        r#"["EOSE","s"]"#,
                    );
                }
            }));
        }
        for h in handles {
            h.join().expect("recorder thread");
        }

        let file_order: Vec<u64> = capture
            .lines()
            .iter()
            .map(|l| l["wire_seq"].as_u64().unwrap_or_default())
            .collect();
        assert_eq!(file_order.len(), 400);

        // FILE order must equal SEQ order even under contention. The sequence
        // number is allocated under the SAME lock as the write, which is what
        // lets a consumer stream the journal instead of buffering and sorting
        // it — and it is the part that a plausible "optimisation" would break:
        // allocating from an atomic OUTSIDE the lock keeps every number unique
        // while letting two threads write them out of order.
        assert!(
            file_order.windows(2).all(|w| w[0] < w[1]),
            "wire_seq must be strictly increasing in FILE order under \
             concurrency; the allocation has escaped the write lock"
        );

        let mut seqs = file_order;
        seqs.sort_unstable();
        seqs.dedup();
        assert_eq!(seqs.len(), 400, "every wire_seq must be unique");
        assert_eq!(seqs.last().copied(), Some(399));
    }

    // ---------------------------------------------------------------------
    // Fail-open. These are the load-bearing tests: the instrument must not be
    // able to break the thing it observes.
    // ---------------------------------------------------------------------

    #[test]
    fn a_failing_sink_never_stops_the_recorder_returning_a_seq() {
        let journal = WireJournal::with_sink(Box::new(AlwaysFails));
        let first = record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);
        let second = record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);

        assert_eq!((first, second), (0, 1), "sequencing survives a dead sink");
        let stats = journal.stats();
        assert_eq!(stats.degraded, Some(Degraded::WriteFailed));
        assert_eq!(stats.written, 0);
        assert_eq!(stats.observed, 2);
    }

    #[test]
    fn a_panicking_sink_is_contained_and_latched() {
        let journal = WireJournal::with_sink(Box::new(Panics));
        let seq = record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);
        assert_eq!(seq, 0, "the panic must not propagate to the caller");
        assert_eq!(journal.stats().degraded, Some(Degraded::SinkPanicked));

        // ...and the NEXT call must still work rather than hitting a poisoned
        // mutex: after a panic the sink is dropped, so recording continues to
        // sequence traffic without exploding a second time.
        let next = record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);
        assert_eq!(next, 1);
    }

    #[test]
    fn an_unopenable_path_yields_a_degraded_journal_not_an_error() {
        let journal = WireJournal::open(Path::new("/proc/definitely/not/writable.ndjson"));
        assert!(journal.is_degraded());
        assert_eq!(
            record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#),
            0,
            "an unopenable journal still sequences traffic"
        );
        assert_eq!(journal.stats().written, 0);
    }

    /// The ENCODE half of the containment claim.
    ///
    /// `emit` runs while holding the lock; a panic escaping it unwinds through
    /// the connection pump and takes the proxied traffic with it. The claim in
    /// this module's docs, in `docs/WIRE_JOURNAL.md` and in
    /// `check_wire_proxy_test_only.sh`'s header is "the recorder panics" — not
    /// "the sink panics" — so serialising has to be inside the `catch_unwind`
    /// too. It was outside.
    #[test]
    fn a_panic_while_encoding_a_line_is_contained_like_a_panicking_sink() {
        let journal = WireJournal::with_sink(Box::new(Capture::default()));

        let seq = journal.emit(|_| PanicsOnSerialize);
        assert_eq!(seq, 0, "the panic must not propagate to the caller");
        assert_eq!(journal.stats().degraded, Some(Degraded::SinkPanicked));

        // ...and sequencing continues, exactly as for a panicking sink.
        assert_eq!(
            record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#),
            1
        );
    }

    /// The honest version of the atomicity claim.
    ///
    /// One `write_all` per line is the smallest unit this can offer, but
    /// `write_all` LOOPS over partial writes, so a reader tailing the file can
    /// observe a line without its terminator. The comment used to promise the
    /// opposite; consumers that treat an unterminated final line as
    /// truncation are relying on the truth, not on the promise.
    #[test]
    fn one_write_all_is_not_one_write_so_a_torn_line_is_observable() {
        let sink = PartialWrites::default();
        let journal = WireJournal::with_sink(Box::new(sink.clone()));
        record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);

        let calls = *sink.calls.lock().expect("calls lock");
        assert!(
            calls > 1,
            "write_all issued {calls} call(s); a single-call guarantee would \
             be needed for 'a reader never sees a line without its terminator' \
             to hold, and there is none"
        );
        assert!(!journal.is_degraded(), "partial writes are not a failure");
        assert_eq!(journal.stats().written, 1);
    }

    #[test]
    fn a_degradation_is_reported_once_and_latched_to_the_first_cause() {
        let journal = WireJournal::with_sink(Box::new(Panics));
        record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);
        record_text(&journal, "c0", Dir::ClientToRelay, r#"["EOSE","s"]"#);
        assert_eq!(
            journal.stats().degraded,
            Some(Degraded::SinkPanicked),
            "the FIRST cause is what triage needs; later writes hit a dropped sink"
        );
    }

    #[test]
    fn a_real_file_journal_round_trips() {
        let dir =
            std::env::temp_dir().join(format!("haven-wire-journal-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let path = dir.join("journal.ndjson");
        let _ = std::fs::remove_file(&path);

        let journal = WireJournal::open(&path);
        record_text(&journal, "c0", Dir::ClientToRelay, r#"["REQ","s",{}]"#);
        record_text(&journal, "c0", Dir::RelayToClient, r#"["EOSE","s"]"#);

        let text = std::fs::read_to_string(&path).expect("journal readable");
        assert_eq!(text.lines().count(), 2);
        assert!(text.ends_with('\n'), "NDJSON lines are newline-terminated");
        assert!(!journal.is_degraded());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn now_ms_is_a_plausible_wall_clock() {
        // Sanity, not precision: after 2020-01-01 and before 2100-01-01.
        let now = now_ms();
        assert!(now > 1_577_836_800_000, "clock must be after 2020");
        assert!(now < 4_102_444_800_000, "clock must be before 2100");
    }
}
