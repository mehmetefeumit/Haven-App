//! Hermetic in-memory Blossom server for Haven's public-profile E2E lane.
//!
//! Two profiles, chosen with `--profile`:
//!
//! - `primal` mimics blossom.primal.net as PrimalHQ/primal-blossom-server
//!   (rev 7e595c9, `src/lib.rs`) behaves, because that is the first server
//!   production uploads to and the one whose download answer broke Haven:
//!   - `PUT /upload`: `Authorization: Nostr <token>`, the token decoded as
//!     padded STANDARD base64 only (`decode_b64`, lib.rs:243-245); the
//!     kind-24242 event's NIP-01 id and BIP-340 signature verified
//!     (`event.verify()`, lib.rs:274); kind 24242 (lib.rs:275-277); an
//!     `expiration` at or before the server's clock refused, an absent one
//!     accepted (lib.rs:287-295); some `t` tag equal to `upload`
//!     (lib.rs:301-306, 316-318); some `x` tag equal to the body's sha256,
//!     required (lib.rs:283, 719). `200` with a descriptor whose `url` is
//!     `http://<Host>/<sha256><.ext>` (lib.rs:760-770, 831-843).
//!   - `GET /<sha256>[.ext]`: `302 Found` to the media host,
//!     `http://<Host's host>:<cdn-port>/uploads2/<s0>/<s1..3>/<s3..5>/<sha256><.ext>`
//!     (lib.rs:477-484, path built at 766-770); the CDN port serves the bytes.
//! - `reference` is the plain BUD-01/02 shape: the token in any base64
//!   spelling, `expiration` required, `201` for a new blob, and `GET` answered
//!   `200` directly.
//!
//! `--control` adds `/__haven-e2e/` on the main port: `POST fault?upload=<503|
//! 401|none>` makes every later upload answer that status, `POST
//! clock?skew=<secs>` moves the clock `expiration` is judged by, and `GET
//! stats` answers counts only. Nothing here logs a hash, a key, an event or a
//! host (Security Rule 15): every log line is a fixed phrase.
//!
//! The simulator reaches it at `http://localhost:<port>`, the Android emulator
//! at `http://10.0.2.2:<port>`; the redirect's host is taken from the request's
//! `Host` header, so one binary serves both. A separate Cargo project (NOT a
//! member of haven-core), so it never enters the app build.

use std::collections::HashMap;
use std::io::Read;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicI64, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use k256::schnorr::{Signature, VerifyingKey};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tiny_http::{Header, Method, Request, Response, Server};

const DEFAULT_PORT: u16 = 3000;
const AUTH_KIND: u64 = 24242;
/// Request-serving threads per listening port.
const WORKERS: usize = 4;
/// The largest upload body accepted; a profile picture is far below it.
const MAX_BODY: u64 = 8 * 1024 * 1024;

/// Which server this process plays.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Profile {
    Primal,
    Reference,
}

/// Why an upload was refused. The counter a refusal bumps, and the fixed
/// phrase it logs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Refusal {
    Fault,
    BadHeader,
    BadBase64,
    BadEvent,
    BadId,
    BadSig,
    WrongKind,
    ExpirationMissing,
    Expired,
    BadAction,
    XMissing,
    XMismatch,
}

impl Refusal {
    const ALL: [Self; 12] = [
        Self::Fault,
        Self::BadHeader,
        Self::BadBase64,
        Self::BadEvent,
        Self::BadId,
        Self::BadSig,
        Self::WrongKind,
        Self::ExpirationMissing,
        Self::Expired,
        Self::BadAction,
        Self::XMissing,
        Self::XMismatch,
    ];

    const fn name(self) -> &'static str {
        match self {
            Self::Fault => "fault",
            Self::BadHeader => "bad_header",
            Self::BadBase64 => "bad_b64",
            Self::BadEvent => "bad_event",
            Self::BadId => "bad_id",
            Self::BadSig => "bad_sig",
            Self::WrongKind => "wrong_kind",
            Self::ExpirationMissing => "expiration_missing",
            Self::Expired => "expired",
            Self::BadAction => "bad_action",
            Self::XMissing => "x_missing",
            Self::XMismatch => "x_mismatch",
        }
    }

    /// Primal answers a malformed header or token 400 and a token that fails
    /// verification 401 (lib.rs:255-318).
    const fn status(self) -> u16 {
        match self {
            Self::Fault => 0,
            Self::BadHeader | Self::BadBase64 | Self::BadEvent => 400,
            _ => 401,
        }
    }
}

#[derive(Clone)]
struct StoredBlob {
    bytes: Vec<u8>,
    content_type: &'static str,
    ext: &'static str,
}

/// The server's whole state: the blobs, the injected fault and clock skew,
/// and the counters `stats` reports.
struct State {
    profile: Profile,
    cdn_port: u16,
    blobs: Mutex<HashMap<String, StoredBlob>>,
    fault: AtomicU16,
    skew: AtomicI64,
    /// `Some` pins the base clock (unit tests); `None` reads the system clock.
    fixed_now: Option<i64>,
    uploads_ok: AtomicU64,
    refused: [AtomicU64; Refusal::ALL.len()],
    redirects: AtomicU64,
    cdn_gets: AtomicU64,
    direct_gets: AtomicU64,
}

impl State {
    fn new(profile: Profile, cdn_port: u16, fixed_now: Option<i64>) -> Self {
        Self {
            profile,
            cdn_port,
            blobs: Mutex::new(HashMap::new()),
            fault: AtomicU16::new(0),
            skew: AtomicI64::new(0),
            fixed_now,
            uploads_ok: AtomicU64::new(0),
            refused: Default::default(),
            redirects: AtomicU64::new(0),
            cdn_gets: AtomicU64::new(0),
            direct_gets: AtomicU64::new(0),
        }
    }

    fn now(&self) -> i64 {
        let base = self.fixed_now.unwrap_or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        });
        base.saturating_add(self.skew.load(Ordering::SeqCst))
    }

    fn refuse(&self, why: Refusal) {
        let index = Refusal::ALL
            .iter()
            .position(|r| *r == why)
            .expect("every refusal is listed");
        self.refused[index].fetch_add(1, Ordering::SeqCst);
        eprintln!("[haven-local-blossom] refused: {}", why.name());
    }

    fn stats_json(&self) -> String {
        let refused: Vec<String> = Refusal::ALL
            .iter()
            .zip(self.refused.iter())
            .map(|(r, n)| format!("\"{}\":{}", r.name(), n.load(Ordering::SeqCst)))
            .collect();
        format!(
            "{{\"uploads_ok\":{},\"refused\":{{{}}},\"redirects\":{},\"cdn_gets\":{},\"direct_gets\":{}}}",
            self.uploads_ok.load(Ordering::SeqCst),
            refused.join(","),
            self.redirects.load(Ordering::SeqCst),
            self.cdn_gets.load(Ordering::SeqCst),
            self.direct_gets.load(Ordering::SeqCst),
        )
    }
}

/// One request, as the handlers see it.
struct Req<'a> {
    method: Method,
    path: &'a str,
    query: &'a str,
    host: Option<&'a str>,
    authorization: Option<&'a str>,
    body: Vec<u8>,
}

/// One response, before it is written.
#[derive(Debug, PartialEq, Eq)]
struct Resp {
    status: u16,
    content_type: &'static str,
    location: Option<String>,
    body: Vec<u8>,
}

impl Resp {
    fn text(status: u16, body: &str) -> Self {
        Self {
            status,
            content_type: "text/plain",
            location: None,
            body: body.as_bytes().to_vec(),
        }
    }
}

/// Which listener a request arrived on.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Listener {
    Main { control: bool },
    Cdn,
}

fn handle(state: &State, listener: Listener, req: &Req<'_>) -> Resp {
    match listener {
        Listener::Cdn => handle_cdn(state, req),
        Listener::Main { control } => {
            if let Some(rest) = req.path.strip_prefix("/__haven-e2e/") {
                return if control {
                    handle_control(state, req, rest)
                } else {
                    Resp::text(404, "not found")
                };
            }
            match req.method {
                Method::Put if req.path == "/upload" => handle_upload(state, req),
                Method::Get => handle_get(state, req),
                _ => Resp::text(404, "not found"),
            }
        }
    }
}

fn handle_control(state: &State, req: &Req<'_>, what: &str) -> Resp {
    match (&req.method, what) {
        (Method::Get, "stats") => Resp {
            status: 200,
            content_type: "application/json",
            location: None,
            body: state.stats_json().into_bytes(),
        },
        (Method::Post, "fault") => match query_value(req.query, "upload") {
            Some("none") => {
                state.fault.store(0, Ordering::SeqCst);
                Resp::text(200, "ok")
            }
            Some(code @ ("401" | "503")) => {
                state
                    .fault
                    .store(code.parse().expect("matched digits"), Ordering::SeqCst);
                Resp::text(200, "ok")
            }
            _ => Resp::text(400, "fault takes upload=401|503|none"),
        },
        (Method::Post, "clock") => match query_value(req.query, "skew").map(str::parse::<i64>) {
            Some(Ok(skew)) => {
                state.skew.store(skew, Ordering::SeqCst);
                Resp::text(200, "ok")
            }
            _ => Resp::text(400, "clock takes skew=<seconds>"),
        },
        _ => Resp::text(404, "not found"),
    }
}

fn handle_upload(state: &State, req: &Req<'_>) -> Resp {
    let fault = state.fault.load(Ordering::SeqCst);
    if fault != 0 {
        state.refuse(Refusal::Fault);
        return Resp::text(fault, "fault injected");
    }
    let hash = sha256_hex(&req.body);
    if let Err(why) = check_auth(state, req.authorization, &hash) {
        state.refuse(why);
        return Resp::text(why.status(), "refused");
    }
    let (content_type, ext) = sniff(&req.body);
    let size = req.body.len();
    let is_new = {
        let mut blobs = state.blobs.lock().expect("blob store mutex poisoned");
        blobs
            .insert(
                hash.clone(),
                StoredBlob {
                    bytes: req.body.clone(),
                    content_type,
                    ext,
                },
            )
            .is_none()
    };
    state.uploads_ok.fetch_add(1, Ordering::SeqCst);
    eprintln!("[haven-local-blossom] upload: ok");
    let host = req.host.unwrap_or("127.0.0.1");
    let (status, url) = match state.profile {
        Profile::Primal => (200, format!("http://{host}/{hash}{ext}")),
        Profile::Reference => (
            if is_new { 201 } else { 200 },
            format!("http://{host}/{hash}"),
        ),
    };
    Resp {
        status,
        content_type: "application/json",
        location: None,
        body: blob_descriptor(&url, &hash, size, content_type, state.now()).into_bytes(),
    }
}

/// Primal's `check_action` for `upload`, or the reference profile's stricter
/// expiration rule, over the decoded token.
fn check_auth(state: &State, header: Option<&str>, body_hash: &str) -> Result<(), Refusal> {
    let header = header.ok_or(Refusal::BadHeader)?;
    let parts: Vec<&str> = header.split_whitespace().collect();
    if parts.len() != 2 || parts[0] != "Nostr" {
        return Err(Refusal::BadHeader);
    }
    let raw = decode_token(state.profile, parts[1]).ok_or(Refusal::BadBase64)?;
    let event: Value = serde_json::from_slice(&raw).map_err(|_| Refusal::BadEvent)?;
    verify_event(&event)?;
    if event["kind"].as_u64() != Some(AUTH_KIND) {
        return Err(Refusal::WrongKind);
    }
    let tags = event["tags"].as_array().ok_or(Refusal::BadEvent)?;
    let mut action_ok = false;
    let mut x_seen = false;
    let mut x_ok = false;
    let mut expiration_seen = false;
    for tag in tags {
        let Some(fields) = tag.as_array() else {
            return Err(Refusal::BadEvent);
        };
        if fields.len() < 2 {
            continue;
        }
        let (Some(name), Some(value)) = (fields[0].as_str(), fields[1].as_str()) else {
            return Err(Refusal::BadEvent);
        };
        match name {
            "expiration" => {
                expiration_seen = true;
                let exp: i64 = value.parse().map_err(|_| Refusal::BadEvent)?;
                if exp <= state.now() {
                    return Err(Refusal::Expired);
                }
            }
            "t" if value == "upload" => action_ok = true,
            "x" => {
                x_seen = true;
                if value.eq_ignore_ascii_case(body_hash) {
                    x_ok = true;
                }
            }
            _ => {}
        }
    }
    if state.profile == Profile::Reference && !expiration_seen {
        return Err(Refusal::ExpirationMissing);
    }
    if !action_ok {
        return Err(Refusal::BadAction);
    }
    if !x_seen {
        return Err(Refusal::XMissing);
    }
    if !x_ok {
        return Err(Refusal::XMismatch);
    }
    Ok(())
}

/// Primal decodes padded STANDARD only; the reference profile takes every
/// spelling BUD-11 and its predecessors have used.
fn decode_token(profile: Profile, token: &str) -> Option<Vec<u8>> {
    match profile {
        Profile::Primal => STANDARD.decode(token).ok(),
        Profile::Reference => [&STANDARD, &URL_SAFE, &URL_SAFE_NO_PAD, &STANDARD_NO_PAD]
            .iter()
            .find_map(|engine| engine.decode(token).ok()),
    }
}

/// NIP-01: the id is the sha256 of `[0,pubkey,created_at,kind,tags,content]`
/// serialized without whitespace, and `sig` is a BIP-340 signature of the id
/// under `pubkey`.
fn verify_event(event: &Value) -> Result<(), Refusal> {
    let pubkey = event["pubkey"].as_str().ok_or(Refusal::BadEvent)?;
    let id = event["id"].as_str().ok_or(Refusal::BadEvent)?;
    let sig = event["sig"].as_str().ok_or(Refusal::BadEvent)?;
    if !event["created_at"].is_u64()
        || !event["kind"].is_u64()
        || !event["tags"].is_array()
        || !event["content"].is_string()
    {
        return Err(Refusal::BadEvent);
    }
    let preimage = serde_json::to_string(&serde_json::json!([
        0,
        pubkey,
        event["created_at"],
        event["kind"],
        event["tags"],
        event["content"],
    ]))
    .map_err(|_| Refusal::BadEvent)?;
    let computed: [u8; 32] = Sha256::digest(preimage.as_bytes()).into();
    let claimed = hex::decode(id).map_err(|_| Refusal::BadEvent)?;
    if claimed.as_slice() != computed {
        return Err(Refusal::BadId);
    }
    let key_bytes = hex::decode(pubkey).map_err(|_| Refusal::BadEvent)?;
    let sig_bytes = hex::decode(sig).map_err(|_| Refusal::BadEvent)?;
    let key = VerifyingKey::from_bytes(&key_bytes).map_err(|_| Refusal::BadSig)?;
    let signature = Signature::try_from(sig_bytes.as_slice()).map_err(|_| Refusal::BadSig)?;
    key.verify_raw(&computed, &signature)
        .map_err(|_| Refusal::BadSig)
}

fn handle_get(state: &State, req: &Req<'_>) -> Resp {
    let hash = blob_hash_from_path(req.path);
    let blob = state
        .blobs
        .lock()
        .expect("blob store mutex poisoned")
        .get(&hash)
        .cloned();
    let Some(blob) = blob else {
        return Resp::text(404, "not found");
    };
    match state.profile {
        Profile::Primal => {
            state.redirects.fetch_add(1, Ordering::SeqCst);
            let host = host_without_port(req.host.unwrap_or("127.0.0.1"));
            Resp {
                status: 302,
                content_type: blob.content_type,
                location: Some(format!(
                    "http://{host}:{}{}",
                    state.cdn_port,
                    cdn_path(&hash, blob.ext)
                )),
                body: Vec::new(),
            }
        }
        Profile::Reference => {
            state.direct_gets.fetch_add(1, Ordering::SeqCst);
            Resp {
                status: 200,
                content_type: blob.content_type,
                location: None,
                body: blob.bytes,
            }
        }
    }
}

/// The media host: only the exact path a redirect named serves the bytes.
fn handle_cdn(state: &State, req: &Req<'_>) -> Resp {
    if req.method != Method::Get {
        return Resp::text(404, "not found");
    }
    let hash = blob_hash_from_path(req.path.rsplit('/').next().unwrap_or(""));
    let blob = state
        .blobs
        .lock()
        .expect("blob store mutex poisoned")
        .get(&hash)
        .cloned();
    match blob {
        Some(blob) if req.path == cdn_path(&hash, blob.ext) => {
            state.cdn_gets.fetch_add(1, Ordering::SeqCst);
            Resp {
                status: 200,
                content_type: blob.content_type,
                location: None,
                body: blob.bytes,
            }
        }
        _ => Resp::text(404, "not found"),
    }
}

/// Primal's media path: `/uploads2/<s0>/<s1..3>/<s3..5>/<sha256><.ext>`.
fn cdn_path(hash: &str, ext: &str) -> String {
    format!(
        "/uploads2/{}/{}/{}/{hash}{ext}",
        &hash[0..1],
        &hash[1..3],
        &hash[3..5]
    )
}

/// The MIME type and extension of an image, from its magic bytes, as
/// Primal's `parse_mimetype` + `MIMETYPE_EXT` give them.
fn sniff(bytes: &[u8]) -> (&'static str, &'static str) {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        ("image/jpeg", ".jpg")
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        ("image/png", ".png")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        ("image/webp", ".webp")
    } else {
        ("application/octet-stream", "")
    }
}

fn host_without_port(host: &str) -> &str {
    if host.starts_with('[') {
        return host.find(']').map_or(host, |end| &host[..=end]);
    }
    host.rsplit_once(':').map_or(host, |(h, _)| h)
}

fn query_value<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(k, _)| *k == key)
        .map(|(_, v)| v)
}

/// The sha256 hex from a request path: the leading slash and any extension
/// dropped, lower-cased.
fn blob_hash_from_path(path: &str) -> String {
    path.trim_start_matches('/')
        .split('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn blob_descriptor(
    url: &str,
    sha256: &str,
    size: usize,
    content_type: &str,
    uploaded: i64,
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

fn json_escape(input: &str) -> String {
    serde_json::to_string(input)
        .map(|quoted| quoted[1..quoted.len() - 1].to_owned())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// The process: arguments, listeners, and the tiny_http glue.
// ---------------------------------------------------------------------------

struct Config {
    port: u16,
    profile: Profile,
    cdn_port: Option<u16>,
    control: bool,
}

fn parse_args(args: &[String]) -> Result<Config, String> {
    let mut config = Config {
        port: std::env::var("HAVEN_BLOSSOM_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_PORT),
        profile: Profile::Reference,
        cdn_port: None,
        control: false,
    };
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--port" => config.port = port_arg(rest.next())?,
            "--cdn-port" => config.cdn_port = Some(port_arg(rest.next())?),
            "--control" => config.control = true,
            "--profile" => {
                config.profile = match rest.next().map(String::as_str) {
                    Some("primal") => Profile::Primal,
                    Some("reference") => Profile::Reference,
                    _ => return Err("--profile takes primal or reference".to_owned()),
                };
            }
            other => {
                config.port = other
                    .parse()
                    .map_err(|_| format!("unknown argument {other:?}"))?
            }
        }
    }
    match (config.profile, config.cdn_port) {
        (Profile::Primal, None) => Err("the primal profile needs --cdn-port".to_owned()),
        (Profile::Reference, Some(_)) => Err("--cdn-port is the primal profile's".to_owned()),
        _ => Ok(config),
    }
}

fn port_arg(value: Option<&String>) -> Result<u16, String> {
    value
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| "a port flag takes a port number".to_owned())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let config = match parse_args(&args) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("[haven-local-blossom] usage: {message}");
            std::process::exit(2);
        }
    };
    let state = Arc::new(State::new(
        config.profile,
        config.cdn_port.unwrap_or(0),
        None,
    ));
    let mut handles = Vec::new();
    let mut listeners = vec![(
        config.port,
        Listener::Main {
            control: config.control,
        },
    )];
    if let Some(cdn) = config.cdn_port {
        listeners.push((cdn, Listener::Cdn));
    }
    for (port, listener) in listeners {
        let server = match Server::http(SocketAddr::from((Ipv4Addr::LOCALHOST, port))) {
            Ok(server) => Arc::new(server),
            Err(_) => {
                eprintln!("[haven-local-blossom] could not bind a port");
                std::process::exit(1);
            }
        };
        // The readiness poll greps this line. It names the port alone: an
        // address would be an IP the log-privacy scanner (rightly) flags.
        println!("[haven-local-blossom] listening on port {port}");
        for _ in 0..WORKERS {
            let server = Arc::clone(&server);
            let state = Arc::clone(&state);
            handles.push(thread::spawn(move || serve(&server, &state, listener)));
        }
    }
    // Serves until the CI teardown sends SIGTERM.
    for handle in handles {
        let _ = handle.join();
    }
}

fn serve(server: &Server, state: &State, listener: Listener) {
    loop {
        if let Ok(request) = server.recv() {
            respond(request, state, listener);
        }
    }
}

fn respond(mut request: Request, state: &State, listener: Listener) {
    let url = request.url().to_owned();
    let (path, query) = url.split_once('?').unwrap_or((url.as_str(), ""));
    let host = header_value(&request, "host");
    let authorization = header_value(&request, "authorization");
    let mut body = Vec::new();
    if request
        .as_reader()
        .take(MAX_BODY)
        .read_to_end(&mut body)
        .is_err()
    {
        return;
    }
    let req = Req {
        method: request.method().clone(),
        path,
        query,
        host: host.as_deref(),
        authorization: authorization.as_deref(),
        body,
    };
    let resp = handle(state, listener, &req);
    let mut response = Response::from_data(resp.body)
        .with_status_code(resp.status)
        .with_header(
            Header::from_bytes(&b"Content-Type"[..], resp.content_type.as_bytes())
                .expect("static content types are ASCII"),
        );
    if let Some(location) = resp.location {
        if let Ok(header) = Header::from_bytes(&b"Location"[..], location.as_bytes()) {
            response = response.with_header(header);
        }
    }
    if request.respond(response).is_err() {
        eprintln!("[haven-local-blossom] a client went away mid-response");
    }
}

fn header_value(request: &Request, name: &str) -> Option<String> {
    request
        .headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use k256::schnorr::SigningKey;

    const NOW: i64 = 1_800_000_000;
    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

    fn state(profile: Profile) -> State {
        State::new(profile, 3001, Some(NOW))
    }

    fn signing_key() -> SigningKey {
        SigningKey::from_bytes(&[7u8; 32]).expect("a valid scalar")
    }

    /// A kind-24242 event signed as a client would sign it.
    fn auth_event(kind: u64, tags: &[&[&str]]) -> Value {
        let key = signing_key();
        let pubkey = hex::encode(key.verifying_key().to_bytes());
        let tags: Vec<Value> = tags
            .iter()
            .map(|t| Value::Array(t.iter().map(|s| Value::String((*s).to_owned())).collect()))
            .collect();
        let created_at = NOW - 5;
        let preimage = serde_json::to_string(&serde_json::json!([
            0,
            pubkey,
            created_at,
            kind,
            tags,
            "Upload \"avatar\"\n"
        ]))
        .unwrap();
        let id: [u8; 32] = Sha256::digest(preimage.as_bytes()).into();
        let sig = key.sign_raw(&id, &[0u8; 32]).unwrap();
        serde_json::json!({
            "id": hex::encode(id),
            "pubkey": pubkey,
            "created_at": created_at,
            "kind": kind,
            "tags": tags,
            "content": "Upload \"avatar\"\n",
            "sig": hex::encode(sig.to_bytes()),
        })
    }

    fn good_tags(hash: &str) -> Vec<Vec<String>> {
        vec![
            vec!["t".into(), "upload".into()],
            vec!["x".into(), hash.into()],
            vec!["expiration".into(), (NOW + 600).to_string()],
        ]
    }

    fn event_with(tags: &[Vec<String>]) -> Value {
        let borrowed: Vec<Vec<&str>> = tags
            .iter()
            .map(|t| t.iter().map(String::as_str).collect())
            .collect();
        let slices: Vec<&[&str]> = borrowed.iter().map(Vec::as_slice).collect();
        auth_event(AUTH_KIND, &slices)
    }

    fn header(event: &Value, engine: &impl Engine) -> String {
        format!(
            "Nostr {}",
            engine.encode(serde_json::to_vec(event).unwrap())
        )
    }

    fn upload(state: &State, auth: Option<&str>, body: &[u8]) -> Resp {
        handle(
            state,
            Listener::Main { control: true },
            &Req {
                method: Method::Put,
                path: "/upload",
                query: "",
                host: Some("10.0.2.2:3000"),
                authorization: auth,
                body: body.to_vec(),
            },
        )
    }

    fn request(state: &State, listener: Listener, method: Method, path: &str, query: &str) -> Resp {
        handle(
            state,
            listener,
            &Req {
                method,
                path,
                query,
                host: Some("10.0.2.2:3000"),
                authorization: None,
                body: Vec::new(),
            },
        )
    }

    fn refused(state: &State, why: Refusal) -> u64 {
        let index = Refusal::ALL.iter().position(|r| *r == why).unwrap();
        state.refused[index].load(Ordering::SeqCst)
    }

    fn good_header(hash: &str) -> String {
        header(&event_with(&good_tags(hash)), &STANDARD)
    }

    #[test]
    fn bip340_vector_1_verifies_through_the_api_the_server_uses() {
        // BIP-340 test vector 1, so `verify_raw` is proven to be BIP-340 over
        // the raw 32-byte message — the form a Nostr id is signed in.
        let key = VerifyingKey::from_bytes(
            &hex::decode("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659")
                .unwrap(),
        )
        .unwrap();
        let msg = hex::decode("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89")
            .unwrap();
        let sig = Signature::try_from(
            hex::decode(
                "6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A",
            )
            .unwrap()
            .as_slice(),
        )
        .unwrap();
        assert!(key.verify_raw(&msg, &sig).is_ok());
    }

    #[test]
    fn primal_accepts_a_padded_standard_token_and_answers_200_with_an_extension() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let resp = upload(&s, Some(&good_header(&hash)), PNG);
        assert_eq!(resp.status, 200);
        let descriptor: Value = serde_json::from_slice(&resp.body).unwrap();
        assert_eq!(
            descriptor["url"],
            format!("http://10.0.2.2:3000/{hash}.png")
        );
        assert_eq!(descriptor["sha256"], hash);
        assert_eq!(descriptor["size"], PNG.len());
        assert_eq!(descriptor["type"], "image/png");
        assert_eq!(s.uploads_ok.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn primal_refuses_url_safe_and_unpadded_tokens() {
        let hash = sha256_hex(PNG);
        // A token whose padded and unpadded spellings coincide would not test
        // the rule, so the event is lengthened until its encoding needs `=`.
        let event = (0..3)
            .map(|n| {
                let mut tags = good_tags(&hash);
                tags.push(vec!["alt".into(), "a".repeat(n)]);
                event_with(&tags)
            })
            .find(|e| serde_json::to_vec(e).unwrap().len() % 3 != 0)
            .unwrap();
        assert!(header(&event, &STANDARD).ends_with('='));
        for engine in [&URL_SAFE_NO_PAD, &STANDARD_NO_PAD] {
            let s = state(Profile::Primal);
            let resp = upload(&s, Some(&header(&event, engine)), PNG);
            assert_eq!(resp.status, 400);
            assert_eq!(refused(&s, Refusal::BadBase64), 1);
            assert_eq!(s.uploads_ok.load(Ordering::SeqCst), 0);
        }
        assert_eq!(
            upload(
                &state(Profile::Primal),
                Some(&header(&event, &STANDARD)),
                PNG
            )
            .status,
            200
        );
    }

    #[test]
    fn reference_accepts_every_base64_spelling() {
        let hash = sha256_hex(PNG);
        let event = event_with(&good_tags(&hash));
        for engine in [&STANDARD, &URL_SAFE, &URL_SAFE_NO_PAD, &STANDARD_NO_PAD] {
            let s = state(Profile::Reference);
            assert_eq!(upload(&s, Some(&header(&event, engine)), PNG).status, 201);
        }
    }

    #[test]
    fn a_tampered_event_is_refused_by_id_and_a_forged_signature_by_sig() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let mut tampered = event_with(&good_tags(&hash));
        tampered["content"] = Value::String("changed".into());
        assert_eq!(
            upload(&s, Some(&header(&tampered, &STANDARD)), PNG).status,
            401
        );
        assert_eq!(refused(&s, Refusal::BadId), 1);

        let mut forged = event_with(&good_tags(&hash));
        let mut sig = hex::decode(forged["sig"].as_str().unwrap()).unwrap();
        sig[63] ^= 1;
        forged["sig"] = Value::String(hex::encode(sig));
        assert_eq!(
            upload(&s, Some(&header(&forged, &STANDARD)), PNG).status,
            401
        );
        assert_eq!(refused(&s, Refusal::BadSig), 1);
        assert_eq!(s.uploads_ok.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_wrong_kind_is_refused() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let event = auth_event(27235, &[&["t", "upload"], &["x", &hash]]);
        assert_eq!(
            upload(&s, Some(&header(&event, &STANDARD)), PNG).status,
            401
        );
        assert_eq!(refused(&s, Refusal::WrongKind), 1);
    }

    #[test]
    fn expiration_is_judged_by_the_skewed_server_clock() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let mut tags = good_tags(&hash);
        tags[2][1] = (NOW + 60).to_string();
        let sixty_seconds = header(&event_with(&tags), &STANDARD);
        assert_eq!(upload(&s, Some(&sixty_seconds), PNG).status, 200);
        assert_eq!(
            request(
                &s,
                Listener::Main { control: true },
                Method::Post,
                "/__haven-e2e/clock",
                "skew=90"
            )
            .status,
            200
        );
        // The device's clock is 90 s behind the server's: a 60 s token is dead
        // on arrival, a 600 s one is not.
        assert_eq!(upload(&s, Some(&sixty_seconds), PNG).status, 401);
        assert_eq!(refused(&s, Refusal::Expired), 1);
        assert_eq!(upload(&s, Some(&good_header(&hash)), PNG).status, 200);
        // `exp <= now` is expired (lib.rs:292): equality is refused too.
        tags[2][1] = (NOW + 90).to_string();
        assert_eq!(
            upload(&s, Some(&header(&event_with(&tags), &STANDARD)), PNG).status,
            401
        );
    }

    #[test]
    fn primal_accepts_a_token_without_expiration_and_reference_does_not() {
        let hash = sha256_hex(PNG);
        let tags = vec![
            vec!["t".to_owned(), "upload".to_owned()],
            vec!["x".to_owned(), hash.clone()],
        ];
        let token = header(&event_with(&tags), &STANDARD);
        assert_eq!(
            upload(&state(Profile::Primal), Some(&token), PNG).status,
            200
        );
        let reference = state(Profile::Reference);
        assert_eq!(upload(&reference, Some(&token), PNG).status, 401);
        assert_eq!(refused(&reference, Refusal::ExpirationMissing), 1);
    }

    #[test]
    fn the_x_tag_is_required_and_must_match_the_body() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let mut tags = good_tags(&hash);
        tags.remove(1);
        assert_eq!(
            upload(&s, Some(&header(&event_with(&tags), &STANDARD)), PNG).status,
            401
        );
        assert_eq!(refused(&s, Refusal::XMissing), 1);
        assert_eq!(
            upload(&s, Some(&good_header(&sha256_hex(b"other"))), PNG).status,
            401
        );
        assert_eq!(refused(&s, Refusal::XMismatch), 1);
    }

    #[test]
    fn some_t_tag_must_name_upload() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let mut tags = good_tags(&hash);
        tags[0][1] = "delete".into();
        assert_eq!(
            upload(&s, Some(&header(&event_with(&tags), &STANDARD)), PNG).status,
            401
        );
        assert_eq!(refused(&s, Refusal::BadAction), 1);
        // "any t tag equals the action" (lib.rs:301-306): a second, matching
        // one is enough.
        tags.push(vec!["t".into(), "upload".into()]);
        assert_eq!(
            upload(&s, Some(&header(&event_with(&tags), &STANDARD)), PNG).status,
            200
        );
    }

    #[test]
    fn a_token_without_a_server_tag_is_accepted() {
        // Primal reads no `server` tag; the good tags carry none.
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        assert!(!good_tags(&hash).iter().any(|t| t[0] == "server"));
        assert_eq!(upload(&s, Some(&good_header(&hash)), PNG).status, 200);
    }

    #[test]
    fn a_missing_or_malformed_header_is_400() {
        let s = state(Profile::Primal);
        assert_eq!(upload(&s, None, PNG).status, 400);
        assert_eq!(upload(&s, Some("Bearer abc"), PNG).status, 400);
        assert_eq!(
            upload(
                &s,
                Some(&format!("Nostr {}", STANDARD.encode(b"not json"))),
                PNG
            )
            .status,
            400
        );
        assert_eq!(refused(&s, Refusal::BadHeader), 2);
        assert_eq!(refused(&s, Refusal::BadEvent), 1);
    }

    #[test]
    fn primal_redirects_get_to_the_cdn_which_serves_the_exact_bytes() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        upload(&s, Some(&good_header(&hash)), PNG);
        for path in [format!("/{hash}"), format!("/{hash}.png")] {
            let resp = request(
                &s,
                Listener::Main { control: false },
                Method::Get,
                &path,
                "",
            );
            assert_eq!(resp.status, 302);
            let location = resp.location.unwrap();
            let expected = format!(
                "http://10.0.2.2:3001/uploads2/{}/{}/{}/{hash}.png",
                &hash[0..1],
                &hash[1..3],
                &hash[3..5]
            );
            assert_eq!(location, expected);
            assert!(resp.body.is_empty());
            let cdn_path = location.trim_start_matches("http://10.0.2.2:3001");
            let served = request(&s, Listener::Cdn, Method::Get, cdn_path, "");
            assert_eq!(served.status, 200);
            assert_eq!(served.body, PNG);
        }
        assert_eq!(s.redirects.load(Ordering::SeqCst), 2);
        assert_eq!(s.cdn_gets.load(Ordering::SeqCst), 2);
        assert_eq!(s.direct_gets.load(Ordering::SeqCst), 0);
        // The media host serves only the path a redirect names.
        assert_eq!(
            request(&s, Listener::Cdn, Method::Get, &format!("/{hash}"), "").status,
            404
        );
        assert_eq!(
            request(
                &s,
                Listener::Main { control: false },
                Method::Get,
                &format!("/{}", "0".repeat(64)),
                ""
            )
            .status,
            404
        );
    }

    #[test]
    fn reference_answers_get_directly() {
        let s = state(Profile::Reference);
        let hash = sha256_hex(PNG);
        let resp = upload(&s, Some(&good_header(&hash)), PNG);
        let descriptor: Value = serde_json::from_slice(&resp.body).unwrap();
        assert_eq!(descriptor["url"], format!("http://10.0.2.2:3000/{hash}"));
        let got = request(
            &s,
            Listener::Main { control: false },
            Method::Get,
            &format!("/{hash}"),
            "",
        );
        assert_eq!((got.status, got.body.as_slice()), (200, PNG));
        assert_eq!(s.direct_gets.load(Ordering::SeqCst), 1);
        assert_eq!(s.redirects.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn an_injected_fault_answers_every_upload_until_reset() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        let control = Listener::Main { control: true };
        assert_eq!(
            request(
                &s,
                control,
                Method::Post,
                "/__haven-e2e/fault",
                "upload=503"
            )
            .status,
            200
        );
        assert_eq!(upload(&s, Some(&good_header(&hash)), PNG).status, 503);
        assert_eq!(upload(&s, Some(&good_header(&hash)), PNG).status, 503);
        assert_eq!(refused(&s, Refusal::Fault), 2);
        assert_eq!(
            request(
                &s,
                control,
                Method::Post,
                "/__haven-e2e/fault",
                "upload=none"
            )
            .status,
            200
        );
        assert_eq!(upload(&s, Some(&good_header(&hash)), PNG).status, 200);
        assert_eq!(
            request(
                &s,
                control,
                Method::Post,
                "/__haven-e2e/fault",
                "upload=500"
            )
            .status,
            400
        );
    }

    #[test]
    fn the_control_surface_exists_only_with_control() {
        let s = state(Profile::Primal);
        let without = Listener::Main { control: false };
        assert_eq!(
            request(&s, without, Method::Get, "/__haven-e2e/stats", "").status,
            404
        );
        assert_eq!(
            request(
                &s,
                without,
                Method::Post,
                "/__haven-e2e/fault",
                "upload=503"
            )
            .status,
            404
        );
        assert_eq!(s.fault.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn stats_are_counts_only() {
        let s = state(Profile::Primal);
        let hash = sha256_hex(PNG);
        upload(&s, Some(&good_header(&hash)), PNG);
        upload(&s, Some(&good_header(&sha256_hex(b"other"))), PNG);
        request(
            &s,
            Listener::Main { control: false },
            Method::Get,
            &format!("/{hash}"),
            "",
        );
        let stats = request(
            &s,
            Listener::Main { control: true },
            Method::Get,
            "/__haven-e2e/stats",
            "",
        );
        let body = String::from_utf8(stats.body).unwrap();
        let parsed: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(parsed["uploads_ok"], 1);
        assert_eq!(parsed["refused"]["x_mismatch"], 1);
        assert_eq!(parsed["redirects"], 1);
        // No hash, key or signature: no run of 16 hex digits at all.
        let longest_hex_run = body
            .split(|c: char| !c.is_ascii_hexdigit())
            .map(str::len)
            .max()
            .unwrap_or(0);
        assert!(longest_hex_run < 16, "stats carried a hex identifier");
    }

    #[test]
    fn sniff_names_the_three_avatar_formats() {
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), ("image/jpeg", ".jpg"));
        assert_eq!(sniff(PNG), ("image/png", ".png"));
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), ("image/webp", ".webp"));
        assert_eq!(sniff(b"plain"), ("application/octet-stream", ""));
    }

    #[test]
    fn the_redirect_host_is_the_request_host_without_its_port() {
        assert_eq!(host_without_port("10.0.2.2:3000"), "10.0.2.2");
        assert_eq!(host_without_port("localhost:3000"), "localhost");
        assert_eq!(host_without_port("localhost"), "localhost");
        assert_eq!(host_without_port("[::1]:3000"), "[::1]");
    }

    #[test]
    fn arguments_pair_the_primal_profile_with_a_cdn_port() {
        let args = |s: &str| s.split(' ').map(str::to_owned).collect::<Vec<_>>();
        let primal = parse_args(&args(
            "--port 3000 --profile primal --cdn-port 3001 --control",
        ))
        .unwrap();
        assert_eq!(
            (primal.port, primal.profile, primal.cdn_port, primal.control),
            (3000, Profile::Primal, Some(3001), true)
        );
        let legacy = parse_args(&args("3002")).unwrap();
        assert_eq!(
            (legacy.port, legacy.profile, legacy.control),
            (3002, Profile::Reference, false)
        );
        assert!(parse_args(&args("--profile primal")).is_err());
        assert!(parse_args(&args("--profile reference --cdn-port 3001")).is_err());
        assert!(parse_args(&args("--profile other")).is_err());
    }

    #[test]
    fn blob_hash_from_path_strips_slash_and_extension() {
        assert_eq!(blob_hash_from_path("/ABC123.jpg"), "abc123");
        assert_eq!(blob_hash_from_path("/deadbeef"), "deadbeef");
    }

    #[test]
    fn json_escape_escapes_quotes_and_backslashes() {
        assert_eq!(json_escape("a\"b\\c"), "a\\\"b\\\\c");
    }
}
