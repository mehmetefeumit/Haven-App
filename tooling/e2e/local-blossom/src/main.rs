//! Hermetic in-memory Blossom (BUD-02) media server for Haven's iOS E2E lane.
//!
//! macOS GitHub runners cannot run the Linux `ghcr.io/hzrd149/blossom-server`
//! container the Android lane uses, so this binary implements just enough of
//! [BUD-02](https://github.com/hzrd149/blossom/blob/master/buds/02.md) to drive
//! the public-profile picture-sharing scenario:
//!
//! - `PUT /upload` — store the raw request body, keyed by its sha256, and
//!   answer with a BUD-02 blob descriptor (`url`/`sha256`/`size`/`type`/
//!   `uploaded`). `201` for a new blob, `200` for a duplicate.
//! - `GET /<sha256>` — serve the stored bytes back with their content type;
//!   `404` for an unknown hash. An optional file extension (`/<sha256>.jpg`)
//!   is tolerated.
//! - `HEAD /upload` — `200` (BUD-06 upload-requirements probe).
//! - `DELETE /<sha256>` — remove the blob; always `200` (idempotent, for the
//!   delete-profile scenario step).
//!
//! The `Authorization: Nostr <base64>` header (BUD-01/02 signed-upload auth) is
//! read but never verified — a real server validates it, and this stub only
//! needs to *not reject* it so the app's signed-upload path is exercised
//! end-to-end. The simulator reaches this server at `http://localhost:<port>`;
//! the port defaults to `3000` and can be overridden by the first CLI argument
//! or the `HAVEN_BLOSSOM_PORT` environment variable. The process serves until
//! the CI teardown sends `SIGTERM`.
//!
//! It is a separate Cargo project (NOT a member of haven-core) so it never
//! enters the app build or the release binary.

use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};
use tiny_http::{Header, Method, Request, Response, Server};

/// Default listen port. Matches the `http://localhost:3000` URL the iOS lane
/// injects via `--dart-define=HAVEN_E2E_BLOSSOM_URL`.
const DEFAULT_PORT: u16 = 3000;

/// Content type applied when an upload omits a `Content-Type` header.
const DEFAULT_CONTENT_TYPE: &str = "image/jpeg";

/// Number of request-serving threads (main thread plus workers). A couple of
/// synthetic users upload/download during the scenario, so a small pool is
/// ample.
const WORKERS: usize = 4;

/// A stored blob: its raw bytes and the content type it was uploaded with.
#[derive(Clone)]
struct StoredBlob {
    bytes: Vec<u8>,
    content_type: String,
}

/// Thread-safe, content-addressed, in-memory blob store.
struct Store {
    blobs: Mutex<HashMap<String, StoredBlob>>,
}

impl Store {
    /// Creates an empty store.
    fn new() -> Self {
        Self {
            blobs: Mutex::new(HashMap::new()),
        }
    }

    /// Stores `bytes` keyed by their sha256; returns the hex hash and whether
    /// the blob was newly inserted (`false` = it was already present).
    fn put(&self, bytes: Vec<u8>, content_type: String) -> (String, bool) {
        let hash = sha256_hex(&bytes);
        let mut guard = self.blobs.lock().expect("blob store mutex poisoned");
        let is_new = !guard.contains_key(&hash);
        guard.insert(hash.clone(), StoredBlob { bytes, content_type });
        (hash, is_new)
    }

    /// Returns a clone of the blob for `hash`, or `None` if unknown.
    fn get(&self, hash: &str) -> Option<StoredBlob> {
        self.blobs
            .lock()
            .expect("blob store mutex poisoned")
            .get(hash)
            .cloned()
    }

    /// Removes the blob for `hash`; returns whether one was present.
    fn delete(&self, hash: &str) -> bool {
        self.blobs
            .lock()
            .expect("blob store mutex poisoned")
            .remove(hash)
            .is_some()
    }
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let port = resolve_port();
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let server = Arc::new(Server::http(addr)?);
    let store = Arc::new(Store::new());

    // The CI readiness poll greps this line (and/or probes the TCP port).
    println!("[haven-local-blossom] listening on 127.0.0.1:{port}");

    let mut handles = Vec::with_capacity(WORKERS.saturating_sub(1));
    for _ in 1..WORKERS {
        let server = Arc::clone(&server);
        let store = Arc::clone(&store);
        handles.push(thread::spawn(move || serve(&server, &store, port)));
    }

    // Serve on the main thread too, so the process blocks here until the CI
    // teardown sends SIGTERM (which terminates every serving thread).
    serve(&server, &store, port);

    for handle in handles {
        let _ = handle.join();
    }
    Ok(())
}

/// Resolves the listen port from the first CLI argument, then
/// `HAVEN_BLOSSOM_PORT`, then the [`DEFAULT_PORT`].
fn resolve_port() -> u16 {
    std::env::args()
        .nth(1)
        .or_else(|| std::env::var("HAVEN_BLOSSOM_PORT").ok())
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_PORT)
}

/// Blocking accept loop: receives requests and dispatches them forever.
fn serve(server: &Server, store: &Store, port: u16) {
    loop {
        match server.recv() {
            Ok(request) => handle_request(request, store, port),
            Err(error) => eprintln!("[haven-local-blossom] recv error: {error}"),
        }
    }
}

/// Routes one request to its BUD-02 handler and logs any I/O error while
/// responding (a broken client connection must not take the server down).
fn handle_request(request: Request, store: &Store, port: u16) {
    let method = request.method().clone();
    let path = request.url().split('?').next().unwrap_or("/").to_owned();

    let result = match method {
        Method::Put if path == "/upload" => handle_upload(request, store, port),
        Method::Head if path == "/upload" => respond(request, 200, Vec::new(), "text/plain"),
        Method::Get => handle_get(request, store, &path),
        Method::Delete => handle_delete(request, store, &path),
        _ => respond(request, 404, b"not found".to_vec(), "text/plain"),
    };

    if let Err(error) = result {
        eprintln!("[haven-local-blossom] respond error: {error}");
    }
}

/// Handles `PUT /upload`: stores the body and answers with a blob descriptor.
fn handle_upload(mut request: Request, store: &Store, port: u16) -> std::io::Result<()> {
    let content_type =
        header_value(&request, "content-type").unwrap_or_else(|| DEFAULT_CONTENT_TYPE.to_owned());
    let host = header_value(&request, "host").unwrap_or_else(|| format!("127.0.0.1:{port}"));
    // Accept but do not verify the BUD-01/02 auth event; a real server checks
    // it, this stub only needs to not reject it.
    let _auth = header_value(&request, "authorization");

    let mut body = Vec::new();
    request.as_reader().read_to_end(&mut body)?;
    let size = body.len();

    let (hash, is_new) = store.put(body, content_type.clone());
    let url = format!("http://{host}/{hash}");
    let descriptor = blob_descriptor(&url, &hash, size, &content_type, now_unix());
    let status = if is_new { 201 } else { 200 };
    respond(request, status, descriptor.into_bytes(), "application/json")
}

/// Handles `GET /<sha256>[.ext]`: serves the stored bytes or `404`.
fn handle_get(request: Request, store: &Store, path: &str) -> std::io::Result<()> {
    let hash = blob_hash_from_path(path);
    match store.get(&hash) {
        Some(blob) => respond(request, 200, blob.bytes, &blob.content_type),
        None => respond(request, 404, b"not found".to_vec(), "text/plain"),
    }
}

/// Handles `DELETE /<sha256>`: removes the blob (idempotent, always `200`).
fn handle_delete(request: Request, store: &Store, path: &str) -> std::io::Result<()> {
    let hash = blob_hash_from_path(path);
    store.delete(&hash);
    respond(request, 200, Vec::new(), "text/plain")
}

/// Extracts the sha256 hex from a request path, dropping the leading slash and
/// any file extension, and lower-casing it.
fn blob_hash_from_path(path: &str) -> String {
    path.trim_start_matches('/')
        .split('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
}

/// Writes `body` with `status` and `content_type` back to the client.
fn respond(
    request: Request,
    status: u16,
    body: Vec<u8>,
    content_type: &str,
) -> std::io::Result<()> {
    let response = Response::from_data(body)
        .with_status_code(status)
        .with_header(content_type_header(content_type));
    request.respond(response)
}

/// Builds a `Content-Type` header, falling back to `application/octet-stream`
/// if `content_type` is not valid ASCII.
fn content_type_header(content_type: &str) -> Header {
    Header::from_bytes(&b"Content-Type"[..], content_type.as_bytes()).unwrap_or_else(|()| {
        Header::from_bytes(&b"Content-Type"[..], &b"application/octet-stream"[..])
            .expect("static content-type header is valid ASCII")
    })
}

/// Returns the first request header whose name case-insensitively matches
/// `name`, as an owned `String`.
fn header_value(request: &Request, name: &str) -> Option<String> {
    request
        .headers()
        .iter()
        .find(|header| header.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str().to_owned())
}

/// Lower-hex sha256 of `bytes`.
fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// Formats a BUD-02 blob descriptor as a JSON object.
fn blob_descriptor(
    url: &str,
    sha256: &str,
    size: usize,
    content_type: &str,
    uploaded: u64,
) -> String {
    format!(
        "{{\"url\":\"{}\",\"sha256\":\"{}\",\"size\":{},\"type\":\"{}\",\"uploaded\":{}}}",
        json_escape(url),
        sha256,
        size,
        json_escape(content_type),
        uploaded,
    )
}

/// Escapes a string for embedding in a JSON string literal.
fn json_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Current Unix time in seconds (0 if the clock is before the epoch).
fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

#[cfg(test)]
mod tests {
    use super::{blob_descriptor, blob_hash_from_path, json_escape, sha256_hex, Store};

    #[test]
    fn sha256_hex_matches_known_vector() {
        // RFC 6234 / NIST test vector: sha256("abc").
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn sha256_hex_of_empty_input() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn upload_then_get_round_trips_bytes_and_type() {
        let store = Store::new();
        let bytes = b"\xff\xd8\xff\xe0 fake jpeg bytes".to_vec();
        let expected_hash = sha256_hex(&bytes);

        let (hash, is_new) = store.put(bytes.clone(), "image/jpeg".to_owned());
        assert_eq!(hash, expected_hash);
        assert!(is_new);

        let fetched = store.get(&hash).expect("blob present after put");
        assert_eq!(fetched.bytes, bytes);
        assert_eq!(fetched.content_type, "image/jpeg");
    }

    #[test]
    fn duplicate_upload_is_not_new() {
        let store = Store::new();
        let (_, first) = store.put(b"dup".to_vec(), "text/plain".to_owned());
        let (_, second) = store.put(b"dup".to_vec(), "text/plain".to_owned());
        assert!(first);
        assert!(!second);
    }

    #[test]
    fn delete_removes_blob_and_is_idempotent() {
        let store = Store::new();
        let (hash, _) = store.put(b"gone".to_vec(), "text/plain".to_owned());
        assert!(store.delete(&hash));
        assert!(store.get(&hash).is_none());
        assert!(!store.delete(&hash));
    }

    #[test]
    fn blob_hash_from_path_strips_slash_and_extension() {
        assert_eq!(blob_hash_from_path("/ABC123.jpg"), "abc123");
        assert_eq!(blob_hash_from_path("/deadbeef"), "deadbeef");
    }

    #[test]
    fn descriptor_has_bud02_fields() {
        let descriptor = blob_descriptor("http://h/abc", "abc", 3, "image/jpeg", 42);
        assert!(descriptor.contains("\"url\":\"http://h/abc\""));
        assert!(descriptor.contains("\"sha256\":\"abc\""));
        assert!(descriptor.contains("\"size\":3"));
        assert!(descriptor.contains("\"type\":\"image/jpeg\""));
        assert!(descriptor.contains("\"uploaded\":42"));
    }

    #[test]
    fn json_escape_escapes_quotes_and_backslashes() {
        assert_eq!(json_escape("a\"b\\c"), "a\\\"b\\\\c");
    }
}
