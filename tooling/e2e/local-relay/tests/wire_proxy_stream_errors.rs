//! A mid-stream WebSocket failure must leave a LINE, not just a log entry.
//!
//! The recorder's contract is "never drop a line". A transport-layer read
//! failure — invalid UTF-8 in a text frame, a protocol violation, a reset
//! without a closing handshake — is precisely the input worth seeing, and it
//! used to produce nothing at all: the journal ended at the connection's last
//! good frame (or at its lone `conn_open`), indistinguishable from a clean
//! close. An oracle cannot fail closed on a truncation it cannot see.

use std::io::{self, Write};
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use haven_local_relay::journal::WireJournal;
use haven_local_relay::proxy::{Proxy, ProxyConfig, Route};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

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

    fn reasons(&self) -> Vec<String> {
        self.lines()
            .iter()
            .filter(|l| l["type"] == "conn_error")
            .filter_map(|l| l["reason"].as_str().map(str::to_owned))
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

/// A well-behaved upstream that accepts and then reads forever.
async fn start_quiet_upstream() -> String {
    let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("upstream binds");
    let addr = listener.local_addr().expect("upstream addr");
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                if let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await {
                    while ws.next().await.is_some() {}
                }
            });
        }
    });
    format!("ws://{addr}")
}

/// An upstream that completes the handshake and then vanishes WITHOUT a
/// closing handshake — the r2c read failure, and the commonest one in the
/// wild.
async fn start_vanishing_upstream() -> String {
    let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .await
        .expect("upstream binds");
    let addr = listener.local_addr().expect("upstream addr");
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                    drop(ws);
                }
            });
        }
    });
    format!("ws://{addr}")
}

/// Opens a RAW connection and completes the WebSocket handshake by hand, so
/// the test can then put bytes on the wire that no WebSocket library would
/// produce.
async fn raw_handshake(addr: SocketAddr) -> tokio::net::TcpStream {
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("raw connect");
    let request = format!(
        "GET / HTTP/1.1\r\n\
         Host: {addr}\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .await
        .expect("handshake request");

    let mut seen = Vec::new();
    let mut byte = [0u8; 1];
    while !seen.ends_with(b"\r\n\r\n") {
        let n = tokio::time::timeout(Duration::from_secs(10), stream.read(&mut byte))
            .await
            .expect("handshake response timed out")
            .expect("handshake response");
        assert!(n == 1, "proxy closed during the handshake");
        seen.push(byte[0]);
    }
    let response = String::from_utf8_lossy(&seen).to_string();
    assert!(
        response.starts_with("HTTP/1.1 101"),
        "the proxy refused the handshake: {response}"
    );
    stream
}

/// A masked client TEXT frame carrying `payload` verbatim, valid UTF-8 or not.
fn masked_text_frame(payload: &[u8]) -> Vec<u8> {
    assert!(payload.len() < 126, "short frames only");
    let mask = [0xA1u8, 0xB2, 0xC3, 0xD4];
    let mut frame = vec![
        0x81,                                                   // FIN + opcode TEXT
        0x80 | u8::try_from(payload.len()).expect("len < 126"), // MASK + length
    ];
    frame.extend_from_slice(&mask);
    for (i, byte) in payload.iter().enumerate() {
        frame.push(byte ^ mask[i % 4]);
    }
    frame
}

async fn settle(capture: &Capture, want: usize) -> Vec<String> {
    for _ in 0..200 {
        let reasons = capture.reasons();
        if reasons.len() >= want {
            return reasons;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    capture.reasons()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// THE case from the finding: a masked text frame whose payload is not valid
/// UTF-8. tungstenite returns `Error::Utf8`, the pump breaks, and the journal
/// used to end with a lone `conn_open`.
#[tokio::test(flavor = "multi_thread")]
async fn an_invalid_utf8_text_frame_is_recorded_not_only_logged() {
    let upstream = start_quiet_upstream().await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(upstream, Arc::clone(&journal)).await;

    let mut raw = raw_handshake(proxy.local_addr()).await;
    // 0xFF 0xFE is not valid UTF-8 in any position.
    raw.write_all(&masked_text_frame(&[0xFF, 0xFE]))
        .await
        .expect("bad frame written");
    raw.flush().await.expect("bad frame flushed");

    let reasons = settle(&capture, 1).await;
    assert_eq!(
        reasons,
        vec!["c2r read failed".to_owned()],
        "a WebSocket-layer read failure must leave a line naming the direction \
         it happened in; the journal was otherwise indistinguishable from a \
         clean close"
    );

    // The failure must be distinguishable from "the connection opened and
    // nothing happened", which is what it looked like before.
    let lines = capture.lines();
    assert_eq!(lines[0]["type"], "conn_open");
    assert!(
        lines.len() > 1,
        "the journal still ends at the conn_open: {lines:?}"
    );
    assert_eq!(
        lines[0]["conn_id"], lines[1]["conn_id"],
        "the failure must be attributed to the connection it happened on"
    );
}

/// A protocol violation — here an UNMASKED frame from a client, which RFC 6455
/// requires a server to reject — takes the same path and must leave the same
/// kind of line.
#[tokio::test(flavor = "multi_thread")]
async fn a_protocol_violation_is_recorded_too() {
    let upstream = start_quiet_upstream().await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(upstream, Arc::clone(&journal)).await;

    let mut raw = raw_handshake(proxy.local_addr()).await;
    // FIN + TEXT, length 5, NO mask bit: illegal from a client.
    raw.write_all(&[0x81, 0x05, b'h', b'e', b'l', b'l', b'o'])
        .await
        .expect("unmasked frame written");
    raw.flush().await.expect("unmasked frame flushed");

    let reasons = settle(&capture, 1).await;
    assert_eq!(reasons, vec!["c2r read failed".to_owned()]);
}

/// The relay→client direction gets its own label, because WHICH PEER produced
/// the bad stream is the part of a read failure that changes a verdict.
#[tokio::test(flavor = "multi_thread")]
async fn a_relay_that_vanishes_mid_stream_is_recorded_against_the_r2c_side() {
    let upstream = start_vanishing_upstream().await;
    let capture = Capture::default();
    let journal = Arc::new(WireJournal::with_sink(Box::new(capture.clone())));
    let proxy = start_proxy(upstream, Arc::clone(&journal)).await;

    let (mut client, _) =
        tokio_tungstenite::connect_async(format!("ws://{}", proxy.local_addr()).as_str())
            .await
            .expect("client connects");
    let _ = tokio::time::timeout(Duration::from_secs(10), async {
        while client.next().await.is_some() {}
    })
    .await;

    let reasons = settle(&capture, 1).await;
    assert!(
        reasons.contains(&"r2c read failed".to_owned()),
        "a relay that dropped the connection without a closing handshake left \
         no trace; saw {reasons:?}"
    );
}
