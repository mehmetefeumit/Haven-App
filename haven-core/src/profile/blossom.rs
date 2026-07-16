//! Blossom (BUD-02/BUD-11) profile-picture upload + anti-SSRF download.
//!
//! Two network operations live here:
//!
//! * [`upload_profile_picture`] — sanitize (EXIF/GPS strip + re-encode via the
//!   avatar pipeline) → content-hash → hand-rolled BUD-02 `PUT /upload` carrying
//!   a BUD-11 kind-24242 authorization signed by the identity key (60 s expiry)
//!   → verify the returned descriptor's `sha256` equals our hash. The PUT is
//!   hand-rolled (not delegated to `nostr-blossom`) because that crate's
//!   `upload_blob` accepts only HTTP 200 and rejects the `201 Created` a
//!   spec-compliant server returns for a *new* blob (BUD-02); Haven accepts any
//!   2xx and treats non-2xx as an error.
//! * [`download_profile_picture`] — the SSRF-hardened fetch of an
//!   attacker-controlled `picture` URL.
//!
//! # Anti-SSRF (Security review F1, BLOCKER)
//!
//! A member's kind-0 `picture` URL is fully attacker-controlled, so a naive
//! download is an SSRF + automatic co-member IP-harvesting primitive. Defenses,
//! all on the download path:
//!
//! * **HTTPS only** ([`require_https`]); plaintext `http://` is accepted only
//!   for loopback/emulator hosts in **debug** builds (release rejects all
//!   `http://`).
//! * **Connect-time IP filtering that gates the ACTUAL connected address.**
//!   Name-based checks are insufficient (DNS rebinding), so the shared
//!   download [`reqwest::Client`] installs a custom
//!   [`reqwest::dns::Resolve`] ([`SsrfGuardResolver`]): reqwest connects to
//!   exactly the addresses the resolver returns and never re-resolves for a
//!   request (redirects are disabled), so filtering inside the resolver gates
//!   the real socket target — closing the rebinding window. A pre-flight
//!   resolution ([`preflight_ssrf_check`]) additionally yields a clean
//!   [`ProfileError::InsecureUrl`] before any connection is attempted. Both
//!   share [`is_forbidden_addr`], which rejects loopback, RFC-1918, link-local
//!   (`169.254/16`, `fe80::/10`), ULA (`fc00::/7`), CGNAT (`100.64/10`),
//!   unspecified, multicast, broadcast, documentation (`2001:db8::/32`) and
//!   reserved ranges. Every IPv4-in-IPv6 embedding is unwrapped and re-checked
//!   as IPv4 — IPv4-mapped (`::ffff:0:0/96`), IPv4-compatible (`::/96`) and
//!   NAT64 (`64:ff9b::/96`) — so an embedded private target cannot bypass it.
//! * **Redirects disabled** (`redirect::Policy::none()`), no cookies (the
//!   `cookies` feature is not enabled), generic UA.
//! * **Size cap enforced twice**: a `Content-Length` precheck AND a streamed
//!   byte counter ([`PROFILE_PICTURE_MAX_DOWNLOAD_BYTES`]) that catches a body
//!   overrunning a lying/absent length.
//! * **Integrity + decode-bomb re-validation**: `sha256(raw) ==` the URL's
//!   trailing 64-hex commitment (when present), then
//!   [`process_inbound_avatar`] re-decodes/re-encodes the bytes.
//!
//! The release-profile loopback/private rejection is `cfg`-gated and NOT
//! exercised by the default debug test run (stated, not claimed): the debug
//! opt-in ([`allow_private_blossom_for_test`]) exempts a small
//! loopback/emulator allowlist so the container e2e can reach a local Blossom.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, OnceLock};

use base64::Engine as _;
use futures::StreamExt;
use nostr::{
    Alphabet, EventBuilder, JsonUtil, Keys, Kind, SingleLetterTag, Tag, TagKind, Timestamp,
};
use sha2::{Digest, Sha256};

use super::config::{
    AVATAR_MIME, BLOSSOM_AUTH_EXPIRY_SECS, BLOSSOM_TIMEOUT, PROFILE_PICTURE_MAX_DOWNLOAD_BYTES,
};
use super::error::{ProfileError, Result};
use super::types::ProfilePicture;
use crate::avatar::image::{process_inbound_avatar, process_own_avatar, ProcessedAvatar};

// ===========================================================================
// URL scheme gate
// ===========================================================================

/// Requires `url` to be `https://`.
///
/// Plaintext `http://` is accepted only in **debug** builds and only for a
/// loopback / emulator-host allowlist (`127.0.0.1`, `::1`, `localhost`,
/// `10.0.2.2`), so local dev and the e2e harness work. Release builds reject
/// every `http://` URL.
///
/// # Errors
///
/// Returns [`ProfileError::InsecureUrl`] for any non-`https` URL outside the
/// debug loopback allowance. The rejected URL is never echoed.
pub fn require_https(url: &url::Url) -> Result<()> {
    match url.scheme() {
        "https" => Ok(()),
        "http" if debug_http_permitted(url) => Ok(()),
        _ => Err(ProfileError::InsecureUrl),
    }
}

/// Debug-only: whether a plaintext `http://` URL targets a permitted
/// loopback / emulator host.
#[cfg(debug_assertions)]
fn debug_http_permitted(url: &url::Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(v4)) => v4.is_loopback() || v4 == Ipv4Addr::new(10, 0, 2, 2),
        Some(url::Host::Ipv6(v6)) => v6.is_loopback(),
        Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        None => false,
    }
}

/// Release stub: plaintext `http://` is never permitted.
#[cfg(not(debug_assertions))]
const fn debug_http_permitted(_url: &url::Url) -> bool {
    false
}

// ===========================================================================
// Anti-SSRF address classification
// ===========================================================================

/// Returns `true` if `ip` must never be dialed for a profile-picture download
/// (loopback / private / link-local / ULA / CGNAT / unspecified / multicast /
/// broadcast / reserved).
///
/// This is the pure, **release-semantics** classifier — it consults no test
/// opt-in — so it can be unit-tested exhaustively. The download path layers the
/// debug loopback exemption on top via [`addr_permitted`].
#[must_use]
pub(crate) fn is_forbidden_addr(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_forbidden_v4(v4),
        IpAddr::V6(v6) => is_forbidden_v6(v6),
    }
}

/// IPv4 forbidden-range classifier.
fn is_forbidden_v4(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    v4.is_loopback()            // 127.0.0.0/8
        || v4.is_private()      // 10/8, 172.16/12, 192.168/16
        || v4.is_link_local()   // 169.254.0.0/16
        || v4.is_broadcast()    // 255.255.255.255
        || v4.is_documentation()// 192.0.2/24, 198.51.100/24, 203.0.113/24
        || v4.is_multicast()    // 224.0.0.0/4
        || v4.is_unspecified()  // 0.0.0.0
        || o[0] == 0            // 0.0.0.0/8 "this network"
        || (o[0] == 100 && (64..=127).contains(&o[1])) // CGNAT 100.64.0.0/10
        || (o[0] == 192 && o[1] == 0 && o[2] == 0)     // 192.0.0.0/24 (IETF)
        || (o[0] == 198 && (o[1] == 18 || o[1] == 19)) // 198.18.0.0/15 (bench)
        || o[0] >= 240 // 240.0.0.0/4 reserved (also covers 255.x broadcast)
}

/// IPv6 forbidden-range classifier.
///
/// Any IPv6 form that embeds an IPv4 address is unwrapped and re-checked as
/// IPv4 so an embedded private/loopback target cannot bypass the filter:
/// * IPv4-**mapped** `::ffff:0:0/96` (`::ffff:127.0.0.1`),
/// * IPv4-**compatible** `::/96` (deprecated; e.g. `::10.0.0.5`),
/// * NAT64 `64:ff9b::/96` (`64:ff9b::10.0.0.5`).
///
/// The `2001:db8::/32` documentation range is rejected outright.
fn is_forbidden_v6(v6: Ipv6Addr) -> bool {
    if let Some(v4) = v6.to_ipv4_mapped() {
        return is_forbidden_v4(v4);
    }
    let seg = v6.segments();
    // 2001:db8::/32 — documentation / examples (RFC 3849).
    if seg[0] == 0x2001 && seg[1] == 0x0db8 {
        return true;
    }
    // IPv4-compatible `::/96` (deprecated) and NAT64 `64:ff9b::/96` both carry an
    // IPv4 address in the low 32 bits — extract and re-check it as IPv4. (`::`
    // and `::1` also fall in `::/96`; their embedded 0.0.0.0/0.0.0.1 are already
    // forbidden as IPv4, and they are covered by the checks below regardless.)
    let is_v4_compatible = seg[..6].iter().all(|&s| s == 0);
    let is_nat64 = seg[0] == 0x0064 && seg[1] == 0xff9b && seg[2..6].iter().all(|&s| s == 0);
    if is_v4_compatible || is_nat64 {
        let o = v6.octets();
        return is_forbidden_v4(Ipv4Addr::new(o[12], o[13], o[14], o[15]));
    }
    v6.is_loopback()                     // ::1
        || v6.is_unspecified()           // ::
        || v6.is_multicast()             // ff00::/8
        || (seg[0] & 0xfe00) == 0xfc00   // ULA fc00::/7
        || (seg[0] & 0xffc0) == 0xfe80 // link-local fe80::/10
}

/// Whether `ip` may be dialed on the download path, layering the debug-only
/// test exemption over the pure [`is_forbidden_addr`] classifier.
fn addr_permitted(ip: IpAddr) -> bool {
    !is_forbidden_addr(ip) || test_exempt_ip(ip)
}

/// Process-static install-once opt-in that relaxes the anti-SSRF filter for a
/// small loopback/emulator allowlist. Debug builds only; unreachable in
/// release (mirrors `relay::allow_ws_loopback_for_test`).
#[cfg(debug_assertions)]
static ALLOW_PRIVATE_BLOSSOM_FOR_TEST: OnceLock<()> = OnceLock::new();

/// Opt in to dialing a loopback/emulator Blossom host for hermetic e2e tests.
///
/// Only the hosts in the download exemption allowlist (`127.0.0.1`, `::1`,
/// `10.0.2.2`) are relaxed even with the opt-in installed; every other private
/// range stays blocked. Install-once via [`OnceLock`].
///
/// # Errors
///
/// Returns `Err` if called more than once in the same process. In release the
/// opt-in is unreachable and this always returns `Err`.
#[cfg(debug_assertions)]
pub fn allow_private_blossom_for_test() -> std::result::Result<(), String> {
    ALLOW_PRIVATE_BLOSSOM_FOR_TEST
        .set(())
        .map_err(|_existing| "allow_private_blossom_for_test already installed".to_string())
}

/// Release stub for [`allow_private_blossom_for_test`] — always errors so
/// release callers fail closed.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn allow_private_blossom_for_test() -> std::result::Result<(), String> {
    Err("allow_private_blossom_for_test is disabled in release builds".to_string())
}

/// Debug-only exemption check for the anti-SSRF filter.
#[cfg(debug_assertions)]
fn test_exempt_ip(ip: IpAddr) -> bool {
    if ALLOW_PRIVATE_BLOSSOM_FOR_TEST.get().is_none() {
        return false;
    }
    match ip {
        IpAddr::V4(v4) => v4.is_loopback() || v4 == Ipv4Addr::new(10, 0, 2, 2),
        IpAddr::V6(v6) => v6.is_loopback(),
    }
}

/// Release stub: no address is ever exempt from the anti-SSRF filter.
#[cfg(not(debug_assertions))]
const fn test_exempt_ip(_ip: IpAddr) -> bool {
    false
}

/// The custom reqwest resolver that filters resolved socket addresses.
///
/// reqwest connects to exactly the addresses this resolver returns and does
/// not re-resolve within a request (redirects are disabled), so filtering here
/// gates the actual connected address and defeats DNS rebinding. Resolution
/// fails closed: if any resolved address is forbidden, the whole resolution is
/// rejected.
struct SsrfGuardResolver;

impl reqwest::dns::Resolve for SsrfGuardResolver {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        Box::pin(async move {
            let host = name.as_str().to_string();
            // Port 0: reqwest overrides it with the URL's port afterwards.
            let resolved = tokio::net::lookup_host((host.as_str(), 0u16))
                .await
                .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send + Sync>)?;
            let mut vetted: Vec<SocketAddr> = Vec::new();
            for addr in resolved {
                if !addr_permitted(addr.ip()) {
                    return Err(Box::<dyn std::error::Error + Send + Sync>::from(
                        "blocked non-public address",
                    ));
                }
                vetted.push(addr);
            }
            if vetted.is_empty() {
                return Err(Box::<dyn std::error::Error + Send + Sync>::from(
                    "host did not resolve",
                ));
            }
            Ok(Box::new(vetted.into_iter()) as reqwest::dns::Addrs)
        })
    }
}

/// Shared, lazily-built download client (redirects disabled, SSRF-filtered
/// resolver, generic UA, bounded timeouts, no cookies).
static DOWNLOAD_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

/// Returns the shared download client, building it on first use.
///
/// Never panics on a build failure (maps to [`ProfileError::Http`]); the build
/// is retried until it succeeds, then cached.
fn download_client() -> Result<&'static reqwest::Client> {
    if let Some(client) = DOWNLOAD_CLIENT.get() {
        return Ok(client);
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("Haven")
        .connect_timeout(BLOSSOM_TIMEOUT)
        .timeout(BLOSSOM_TIMEOUT)
        .dns_resolver(Arc::new(SsrfGuardResolver))
        .build()
        .map_err(ProfileError::http)?;
    // A racing initializer may win; either way `get()` is then `Some`.
    let _ = DOWNLOAD_CLIENT.set(client);
    Ok(DOWNLOAD_CLIENT.get().expect("download client just set"))
}

// ===========================================================================
// Upload
// ===========================================================================

/// The kind of a BUD-11 Blossom authorization event (`24242`).
const BLOSSOM_AUTH_KIND: u16 = 24242;

/// A BUD-02 blob descriptor as returned by `PUT /upload` / `GET /list`.
///
/// Only `url` and `sha256` are load-bearing for Haven (they are re-verified
/// against our own content hash). `size` / `type` / `uploaded` are part of the
/// spec response but unused here, so they are ignored by the deserializer. Both
/// required fields being non-`Option` means a malformed or `sha256`-less body
/// fails to parse and is surfaced as an error (never a silent accept).
#[derive(serde::Deserialize)]
struct BlobDescriptor {
    /// The public URL at which the blob can be fetched.
    url: String,
    /// Lowercase hex sha256 the server computed over the stored bytes.
    sha256: String,
}

/// Builds the `Authorization: Nostr <base64>` header value carrying a signed
/// BUD-11 kind-24242 upload authorization for the blob whose sha256 hex is
/// `sha256_hex`.
///
/// The event carries `["t","upload"]`, `["expiration", now + 60 s]` and
/// `["x", <sha256_hex>]`, a short human-readable `content`, and `created_at =
/// now`, signed by the identity `keys`. The JSON is encoded with **standard**
/// (padded) base64 — the encoding the reference `nostr-blossom` crate and the
/// deployed servers (hzrd149's blossom-server, primal) actually accept.
///
/// # Errors
///
/// [`ProfileError::Build`] if event signing fails.
fn build_upload_auth_header(keys: &Keys, sha256_hex: &str) -> Result<String> {
    let expiration = Timestamp::now() + std::time::Duration::from_secs(BLOSSOM_AUTH_EXPIRY_SECS);
    let x_tag = Tag::custom(
        TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::X)),
        [sha256_hex],
    );
    let event = EventBuilder::new(
        Kind::Custom(BLOSSOM_AUTH_KIND),
        "Haven profile picture upload",
    )
    .tags([Tag::hashtag("upload"), Tag::expiration(expiration), x_tag])
    .sign_with_keys(keys)
    .map_err(ProfileError::build)?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(event.as_json());
    Ok(format!("Nostr {encoded}"))
}

/// Uploads a sanitized profile picture to `server` and returns the resolved
/// [`ProfilePicture`].
///
/// Pipeline: [`require_https`] → [`process_own_avatar`] (EXIF/GPS strip +
/// re-encode) → content-hash → hand-rolled BUD-02 `PUT /upload` (identity-signed
/// BUD-11 kind-24242 auth, 60 s expiry) over the shared SSRF-guarded client
/// under [`BLOSSOM_TIMEOUT`] → re-check the returned descriptor URL is HTTPS →
/// assert the descriptor's `sha256` equals our post-pipeline hash. The uploaded
/// bytes are the canonical re-encode, so the hash commits to sanitized content
/// (never the raw input).
///
/// The upload is hand-rolled rather than delegated to `nostr-blossom` because
/// that crate's `upload_blob` accepts only HTTP 200 and rejects the `201
/// Created` a spec-compliant server returns for a *new* blob (BUD-02). Any 2xx
/// is accepted here; any other status is an error.
///
/// # Errors
///
/// * [`ProfileError::InsecureUrl`] if `server` (or the returned descriptor URL)
///   is not HTTPS.
/// * [`ProfileError::Image`] if the image fails the sanitize pipeline.
/// * [`ProfileError::Timeout`] / [`ProfileError::Blossom`] on upload failure.
/// * [`ProfileError::HashMismatch`] if the server's descriptor hash disagrees.
pub async fn upload_profile_picture(
    keys: &Keys,
    server: &url::Url,
    raw: &[u8],
) -> Result<ProfilePicture> {
    require_https(server)?;
    let processed = process_own_avatar(raw)?;
    // The shared client re-filters at connect time (anti-SSRF, redirects off,
    // bounded timeouts) — the same hardened seam the download path uses.
    upload_with_client(download_client()?, keys, server, processed).await
}

/// The transport core shared by the public upload and its tests: builds the
/// BUD-11 auth, `PUT`s the canonical bytes to `<server>/upload`, and validates
/// the returned BUD-02 descriptor. Assumes `server` has been scheme-vetted by
/// the caller. Splitting the client out lets the tests drive it with a plain
/// (non-SSRF) client against a loopback mock, mirroring `download_with_client`.
///
/// # Errors
///
/// As [`upload_profile_picture`].
async fn upload_with_client(
    client: &reqwest::Client,
    keys: &Keys,
    server: &url::Url,
    processed: ProcessedAvatar,
) -> Result<ProfilePicture> {
    let expected_hex = hex::encode(processed.content_hash);
    let upload_url = server.join("upload").map_err(|_| ProfileError::BadUrl)?;
    let auth_header = build_upload_auth_header(keys, &expected_hex)?;

    let response = tokio::time::timeout(
        BLOSSOM_TIMEOUT,
        client
            .put(upload_url)
            .header(reqwest::header::AUTHORIZATION, auth_header)
            .header(reqwest::header::CONTENT_TYPE, AVATAR_MIME)
            .body(processed.canonical.to_vec())
            .send(),
    )
    .await
    .map_err(|_| ProfileError::Timeout)?
    .map_err(ProfileError::http)?;

    // BUD-02: `201 Created` for a new blob, `200 OK` for an already-present one;
    // accept any 2xx, reject everything else.
    let status = response.status();
    if !status.is_success() {
        return Err(ProfileError::blossom(format!("upload status {status}")));
    }

    let body = read_body_capped(response, PROFILE_PICTURE_MAX_DOWNLOAD_BYTES).await?;
    let descriptor: BlobDescriptor =
        serde_json::from_slice(&body).map_err(ProfileError::blossom)?;

    // The URL the server hands back is where members will fetch — it must be
    // HTTPS too (a server could return an http:// or private URL).
    let descriptor_url = url::Url::parse(&descriptor.url).map_err(|_| ProfileError::BadUrl)?;
    require_https(&descriptor_url)?;

    if !descriptor.sha256.eq_ignore_ascii_case(&expected_hex) {
        return Err(ProfileError::HashMismatch);
    }

    Ok(ProfilePicture {
        url: descriptor.url,
        sha256_hex: expected_hex,
        canonical: processed.canonical,
        thumbnail: processed.thumbnail,
    })
}

// ===========================================================================
// Download
// ===========================================================================

/// Downloads and re-validates a member's profile picture from an
/// attacker-controlled URL, applying all anti-SSRF defenses (module docs).
///
/// # Errors
///
/// * [`ProfileError::BadUrl`] if `url` does not parse.
/// * [`ProfileError::InsecureUrl`] if the URL is not HTTPS or resolves to a
///   forbidden (loopback/private/…) address.
/// * [`ProfileError::TooLarge`] on a `Content-Length` or streamed-size overrun.
/// * [`ProfileError::HashMismatch`] if the bytes disagree with the URL hash.
/// * [`ProfileError::Http`] / [`ProfileError::Timeout`] on transport failure.
/// * [`ProfileError::Image`] if the bytes fail decode-bomb re-validation.
pub async fn download_profile_picture(url: &str) -> Result<ProfilePicture> {
    let parsed = url::Url::parse(url).map_err(|_| ProfileError::BadUrl)?;
    require_https(&parsed)?;
    // Pre-flight resolution + filter: fail fast with a clean InsecureUrl.
    preflight_ssrf_check(&parsed).await?;
    // The shared client's resolver re-filters at connect time (anti-rebinding).
    download_with_client(download_client()?, &parsed).await
}

/// Resolves `url`'s host and rejects if any resolved address is forbidden.
///
/// This is the fail-fast pre-flight; the shared client's resolver enforces the
/// same check at connect time (which is the load-bearing anti-rebinding gate).
///
/// # Errors
///
/// [`ProfileError::InsecureUrl`] if the host resolves to a forbidden address or
/// does not resolve; [`ProfileError::Http`] on a resolver I/O error.
async fn preflight_ssrf_check(url: &url::Url) -> Result<()> {
    let host = url.host_str().ok_or(ProfileError::BadUrl)?;
    let port = url.port_or_known_default().unwrap_or(443);
    let mut resolved = tokio::net::lookup_host((host, port))
        .await
        .map_err(ProfileError::http)?
        .peekable();
    if resolved.peek().is_none() {
        return Err(ProfileError::InsecureUrl);
    }
    for addr in resolved {
        if !addr_permitted(addr.ip()) {
            return Err(ProfileError::InsecureUrl);
        }
    }
    Ok(())
}

/// The transport core shared by the public download and its tests: issues the
/// GET, enforces the size caps and hash/decode re-validation. Assumes `url`
/// has already been scheme- and SSRF-vetted by the caller.
///
/// # Errors
///
/// As [`download_profile_picture`] (minus the URL-parse / SSRF pre-flight the
/// caller performs).
async fn download_with_client(client: &reqwest::Client, url: &url::Url) -> Result<ProfilePicture> {
    let response = tokio::time::timeout(BLOSSOM_TIMEOUT, client.get(url.clone()).send())
        .await
        .map_err(|_| ProfileError::Timeout)?
        .map_err(ProfileError::http)?;

    if !response.status().is_success() {
        return Err(ProfileError::http(format!("status {}", response.status())));
    }

    // Content-Length precheck: reject a header claiming more than the cap.
    if let Some(len) = response.content_length() {
        if len > PROFILE_PICTURE_MAX_DOWNLOAD_BYTES {
            return Err(ProfileError::TooLarge);
        }
    }

    let raw = read_body_capped(response, PROFILE_PICTURE_MAX_DOWNLOAD_BYTES).await?;

    // sha256(raw) must match the URL's trailing 64-hex commitment when present.
    let raw_hash_hex = hex::encode(Sha256::digest(&raw));
    if let Some(expected) = extract_sha256_from_url(url) {
        if raw_hash_hex != expected {
            return Err(ProfileError::HashMismatch);
        }
    }

    // Decode-bomb / polyglot re-validation: re-decode + re-encode the bytes.
    let processed = process_inbound_avatar(&raw)?;

    Ok(ProfilePicture {
        url: url.to_string(),
        sha256_hex: raw_hash_hex,
        canonical: processed.canonical,
        thumbnail: processed.thumbnail,
    })
}

/// Streams a response body into a `Vec`, rejecting once the accumulated size
/// exceeds `cap` (catches a body that overruns a lying/absent `Content-Length`).
///
/// # Errors
///
/// [`ProfileError::TooLarge`] on overrun; [`ProfileError::Http`] on a stream
/// read error.
async fn read_body_capped(response: reqwest::Response, cap: u64) -> Result<Vec<u8>> {
    let cap_usize = usize::try_from(cap).unwrap_or(usize::MAX);
    let mut stream = response.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(ProfileError::http)?;
        if buf.len().saturating_add(chunk.len()) > cap_usize {
            return Err(ProfileError::TooLarge);
        }
        buf.extend_from_slice(&chunk);
    }
    Ok(buf)
}

/// Extracts a Blossom content-address (a trailing 64-hex path segment, with an
/// optional file extension) from `url`, lowercased. Returns `None` when the
/// last path segment is not a 64-char hex string.
fn extract_sha256_from_url(url: &url::Url) -> Option<String> {
    let last = url.path_segments()?.next_back()?;
    let stem = last.split('.').next().unwrap_or(last);
    if stem.len() == 64 && stem.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(stem.to_ascii_lowercase())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    // A mockito `Server` (and its mock guards) must live for the whole test so
    // the async HTTP round-trips can reach it; `significant_drop_tightening`'s
    // "drop earlier" suggestion is a false positive here.
    #![allow(clippy::significant_drop_tightening)]

    use super::*;
    use base64::Engine;
    use image::{codecs::jpeg::JpegEncoder, RgbImage};
    use std::io::Cursor;

    // ---- image fixture -----------------------------------------------------

    fn tiny_jpeg() -> Vec<u8> {
        let mut img = RgbImage::new(64, 64);
        for (x, y, px) in img.enumerate_pixels_mut() {
            let r = u8::try_from(x % 256).unwrap_or(0);
            let g = u8::try_from(y % 256).unwrap_or(0);
            *px = image::Rgb([r, g, 96]);
        }
        let mut out = Vec::new();
        JpegEncoder::new_with_quality(Cursor::new(&mut out), 90)
            .encode_image(&img)
            .expect("encode jpeg");
        out
    }

    fn no_redirect_client() -> reqwest::Client {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("build test client")
    }

    fn descriptor_json(base: &str, sha_hex: &str, size: usize) -> String {
        format!(
            r#"{{"url":"{base}/{sha_hex}","sha256":"{sha_hex}","size":{size},"type":"image/jpeg","uploaded":1700000000}}"#
        )
    }

    // ---- require_https -----------------------------------------------------

    #[test]
    fn require_https_accepts_https() {
        let url = url::Url::parse("https://blossom.example/abc").unwrap();
        assert!(require_https(&url).is_ok());
    }

    #[test]
    fn require_https_rejects_plain_http_public_host() {
        let url = url::Url::parse("http://blossom.example/abc").unwrap();
        assert!(matches!(
            require_https(&url),
            Err(ProfileError::InsecureUrl)
        ));
    }

    #[test]
    fn require_https_allows_loopback_http_in_debug() {
        // Debug-only allowance so mockito (http://127.0.0.1) + local dev work.
        for u in [
            "http://127.0.0.1:3000/x",
            "http://localhost:3000/x",
            "http://[::1]:3000/x",
            "http://10.0.2.2:3000/x",
        ] {
            let url = url::Url::parse(u).unwrap();
            assert!(require_https(&url).is_ok(), "{u} must be allowed in debug");
        }
    }

    // ---- is_forbidden_addr (anti-SSRF classifier) --------------------------

    #[test]
    fn download_rejects_loopback_ip() {
        assert!(is_forbidden_addr("127.0.0.1".parse().unwrap()));
        assert!(is_forbidden_addr("127.9.9.9".parse().unwrap()));
        assert!(is_forbidden_addr("::1".parse().unwrap()));
        // IPv4-mapped loopback must not bypass.
        assert!(is_forbidden_addr("::ffff:127.0.0.1".parse().unwrap()));
    }

    #[test]
    fn download_rejects_rfc1918() {
        assert!(is_forbidden_addr("10.0.0.5".parse().unwrap()));
        assert!(is_forbidden_addr("172.16.0.1".parse().unwrap()));
        assert!(is_forbidden_addr("172.31.255.255".parse().unwrap()));
        assert!(is_forbidden_addr("192.168.1.1".parse().unwrap()));
        // IPv4-mapped RFC-1918 must not bypass.
        assert!(is_forbidden_addr("::ffff:192.168.1.1".parse().unwrap()));
    }

    #[test]
    fn download_rejects_link_local() {
        assert!(is_forbidden_addr("169.254.1.1".parse().unwrap()));
        assert!(is_forbidden_addr("fe80::1".parse().unwrap()));
        assert!(is_forbidden_addr("fe80::abcd:1234".parse().unwrap()));
    }

    #[test]
    fn download_rejects_ula() {
        assert!(is_forbidden_addr("fc00::1".parse().unwrap()));
        assert!(is_forbidden_addr("fd12:3456::1".parse().unwrap()));
    }

    #[test]
    fn download_rejects_cgnat_unspecified_multicast_broadcast() {
        assert!(is_forbidden_addr("100.64.0.1".parse().unwrap()));
        assert!(is_forbidden_addr("100.127.255.255".parse().unwrap()));
        assert!(is_forbidden_addr("0.0.0.0".parse().unwrap()));
        assert!(is_forbidden_addr("::".parse().unwrap()));
        assert!(is_forbidden_addr("224.0.0.1".parse().unwrap()));
        assert!(is_forbidden_addr("ff02::1".parse().unwrap()));
        assert!(is_forbidden_addr("255.255.255.255".parse().unwrap()));
        assert!(is_forbidden_addr("240.0.0.1".parse().unwrap()));
    }

    #[test]
    fn rejects_ipv4_compatible_embedded_private() {
        // Deprecated IPv4-compatible `::/96` embedding a private/loopback IPv4
        // must be unwrapped and rejected (not just the `::ffff:` mapped form).
        assert!(is_forbidden_addr("::10.0.0.5".parse().unwrap()));
        assert!(is_forbidden_addr("::192.168.1.1".parse().unwrap()));
        assert!(is_forbidden_addr("::127.0.0.1".parse().unwrap()));
    }

    #[test]
    fn rejects_nat64_embedded_private() {
        // NAT64 `64:ff9b::/96` embedding a private IPv4 must be rejected.
        assert!(is_forbidden_addr("64:ff9b::10.0.0.5".parse().unwrap()));
        assert!(is_forbidden_addr("64:ff9b::192.168.0.1".parse().unwrap()));
        assert!(is_forbidden_addr("64:ff9b::169.254.1.1".parse().unwrap()));
    }

    #[test]
    fn rejects_ipv6_documentation() {
        // 2001:db8::/32 (RFC 3849 documentation) must never be dialed.
        assert!(is_forbidden_addr("2001:db8::1".parse().unwrap()));
        assert!(is_forbidden_addr("2001:db8:dead:beef::1".parse().unwrap()));
    }

    #[test]
    fn public_addresses_are_allowed() {
        // A handful of clearly-public addresses must NOT be forbidden.
        assert!(!is_forbidden_addr("1.1.1.1".parse().unwrap()));
        assert!(!is_forbidden_addr("8.8.8.8".parse().unwrap()));
        assert!(!is_forbidden_addr("93.184.216.34".parse().unwrap()));
        assert!(!is_forbidden_addr("2606:4700:4700::1111".parse().unwrap()));
        // A public 2001:: address that is NOT the db8 documentation block.
        assert!(!is_forbidden_addr("2001:4860:4860::8888".parse().unwrap()));
        // 100.63 and 100.128 are OUTSIDE the CGNAT block → public.
        assert!(!is_forbidden_addr("100.63.255.255".parse().unwrap()));
        assert!(!is_forbidden_addr("100.128.0.0".parse().unwrap()));
    }

    #[test]
    fn download_client_builds() {
        // Exercises the shared client construction (with the SSRF resolver)
        // without any network I/O.
        assert!(download_client().is_ok());
    }

    // ---- full download path: SSRF pre-flight reject ------------------------

    #[tokio::test]
    async fn download_full_path_rejects_loopback_url() {
        // The complete download_profile_picture entry must reject a loopback
        // URL at the pre-flight (release-like path: no opt-in installed in this
        // test binary). Nothing listens on port 9; the reject happens before
        // any connection is attempted.
        let sha = "a".repeat(64);
        let err = download_profile_picture(&format!("https://127.0.0.1:9/{sha}"))
            .await
            .expect_err("loopback URL must be rejected");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    }

    #[tokio::test]
    async fn download_full_path_rejects_rfc1918_url() {
        let sha = "b".repeat(64);
        let err = download_profile_picture(&format!("https://192.168.0.1:9/{sha}"))
            .await
            .expect_err("rfc1918 URL must be rejected");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    }

    #[tokio::test]
    async fn download_rejects_non_https() {
        let err = download_profile_picture("ftp://example.com/x")
            .await
            .expect_err("non-https must be rejected");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    }

    // ---- upload (mockito) --------------------------------------------------
    //
    // These drive the transport core `upload_with_client` with a plain
    // (non-SSRF) client so the loopback mock is reachable, mirroring the
    // download-core tests. The public `upload_profile_picture` wraps this with
    // `require_https` + the shared SSRF-guarded client (exercised by the
    // non-https reject test below and the `#[ignore]`d live round-trip).

    /// Runs the upload happy path against a mock returning `status`, asserting
    /// the fully-resolved [`ProfilePicture`]. Parameterized so both the BUD-02
    /// `201 Created` (new blob) and `200 OK` (existing blob) responses are
    /// proven to succeed — the core of the 200-only foot-gun fix.
    async fn upload_happy_path_with_status(status: usize) {
        let mut server = mockito::Server::new_async().await;
        let raw = tiny_jpeg();
        let processed = process_own_avatar(&raw).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);
        let body = descriptor_json(&server.url(), &sha_hex, processed.canonical.len());
        let _m = server
            .mock("PUT", "/upload")
            .with_status(status)
            .with_body(body)
            .create_async()
            .await;

        let keys = Keys::generate();
        let server_url = url::Url::parse(&server.url()).unwrap();
        let pic = upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
            .await
            .unwrap_or_else(|e| panic!("upload with status {status} must succeed: {e:?}"));
        assert_eq!(pic.sha256_hex, sha_hex);
        assert!(pic.url.ends_with(&sha_hex));
        assert!(!pic.canonical.is_empty());
        assert!(!pic.thumbnail.is_empty());
    }

    #[tokio::test]
    async fn upload_accepts_201_created() {
        // BUD-02: a NEW blob is `201 Created`. The pinned nostr-blossom
        // `upload_blob` accepted only 200 and rejected this; the hand-rolled
        // PUT MUST accept it. This is the correctness fix.
        upload_happy_path_with_status(201).await;
    }

    #[tokio::test]
    async fn upload_accepts_200_ok() {
        // BUD-02: an already-present blob is `200 OK` — must also succeed.
        upload_happy_path_with_status(200).await;
    }

    #[tokio::test]
    async fn upload_hash_is_post_pipeline_not_raw_input() {
        let mut server = mockito::Server::new_async().await;
        let raw = tiny_jpeg();
        let processed = process_own_avatar(&raw).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);
        // Sanity: the sanitized-bytes hash differs from the raw-input hash.
        let raw_hash = hex::encode(Sha256::digest(&raw));
        assert_ne!(sha_hex, raw_hash, "canonical hash must not equal raw hash");
        let _m = server
            .mock("PUT", "/upload")
            .with_status(201)
            .with_body(descriptor_json(
                &server.url(),
                &sha_hex,
                processed.canonical.len(),
            ))
            .create_async()
            .await;

        let keys = Keys::generate();
        let server_url = url::Url::parse(&server.url()).unwrap();
        let pic = upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
            .await
            .expect("upload");
        assert_eq!(
            pic.sha256_hex, sha_hex,
            "reported hash is the sanitized one"
        );
    }

    #[tokio::test]
    async fn upload_auth_header_is_standard_base64_24242_event() {
        let mut server = mockito::Server::new_async().await;
        let raw = tiny_jpeg();
        let processed = process_own_avatar(&raw).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);

        let captured: Arc<std::sync::Mutex<Option<String>>> = Arc::new(std::sync::Mutex::new(None));
        let cap = Arc::clone(&captured);
        let _m = server
            .mock("PUT", "/upload")
            .match_request(move |req| {
                if let Some(h) = req.header("authorization").first() {
                    if let Ok(s) = h.to_str() {
                        *cap.lock().unwrap() = Some(s.to_string());
                    }
                }
                true
            })
            .with_status(201)
            .with_body(descriptor_json(
                &server.url(),
                &sha_hex,
                processed.canonical.len(),
            ))
            .create_async()
            .await;

        let keys = Keys::generate();
        let server_url = url::Url::parse(&server.url()).unwrap();
        upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
            .await
            .expect("upload");

        let header = captured
            .lock()
            .unwrap()
            .clone()
            .expect("authorization header captured");
        let b64 = header
            .strip_prefix("Nostr ")
            .expect("header uses the `Nostr <base64>` scheme");
        // The hand-rolled header MUST use STANDARD (padded) base64 — the
        // encoding the reference crate + deployed servers accept. Decoding with
        // the STANDARD engine proves it (a url-safe/no-pad payload would fail).
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .expect("auth header is standard padded base64");
        let event: nostr::Event =
            serde_json::from_slice(&decoded).expect("auth payload is a nostr event");

        assert_eq!(event.kind.as_u16(), 24242, "auth event kind is 24242");
        assert_eq!(
            event.pubkey,
            keys.public_key(),
            "auth event signed by identity key"
        );
        assert!(event.verify().is_ok(), "auth event signature verifies");

        let now = nostr::Timestamp::now().as_secs();
        assert!(
            event.created_at.as_secs() <= now + 1,
            "created_at is in the past"
        );

        let mut saw_t_upload = false;
        let mut saw_x = false;
        let mut expiration_future = false;
        for tag in event.tags.iter() {
            let s = tag.as_slice();
            if s.len() >= 2 && s[0] == "t" && s[1] == "upload" {
                saw_t_upload = true;
            }
            if s.len() >= 2 && s[0] == "x" && s[1] == sha_hex {
                saw_x = true;
            }
            if s.len() >= 2 && s[0] == "expiration" {
                if let Ok(exp) = s[1].parse::<u64>() {
                    expiration_future = exp > now;
                }
            }
        }
        assert!(saw_t_upload, "auth carries t=upload: {:?}", event.tags);
        assert!(
            saw_x,
            "auth carries x = sanitized-bytes hash: {:?}",
            event.tags
        );
        assert!(
            expiration_future,
            "expiration is in the future: {:?}",
            event.tags
        );
    }

    #[tokio::test]
    async fn upload_500_maps_to_error_not_panic() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("PUT", "/upload")
            .with_status(500)
            .with_body("boom")
            .create_async()
            .await;
        let keys = Keys::generate();
        let server_url = url::Url::parse(&server.url()).unwrap();
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let err = upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
            .await
            .expect_err("500 is an error");
        assert!(matches!(err, ProfileError::Blossom(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_4xx_maps_to_error_not_panic() {
        // A 4xx (e.g. 401 auth rejected) is non-2xx → error, never a panic.
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("PUT", "/upload")
            .with_status(401)
            .with_body("unauthorized")
            .create_async()
            .await;
        let keys = Keys::generate();
        let server_url = url::Url::parse(&server.url()).unwrap();
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let err = upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
            .await
            .expect_err("4xx is an error");
        assert!(matches!(err, ProfileError::Blossom(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_descriptor_hash_mismatch_rejected() {
        let mut server = mockito::Server::new_async().await;
        // Server echoes a DIFFERENT sha than the uploaded bytes → HashMismatch.
        let bad_sha = "0".repeat(64);
        let _m = server
            .mock("PUT", "/upload")
            .with_status(201)
            .with_body(descriptor_json(&server.url(), &bad_sha, 123))
            .create_async()
            .await;
        let keys = Keys::generate();
        let server_url = url::Url::parse(&server.url()).unwrap();
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let err = upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
            .await
            .expect_err("mismatched sha is rejected");
        assert!(matches!(err, ProfileError::HashMismatch), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_rejects_malformed_descriptor() {
        // A 2xx body that is not a valid BUD-02 descriptor — non-JSON, or a JSON
        // object missing the required `sha256` — must be a Blossom error, never
        // a silent accept or a panic.
        for body in ["not a json body", r#"{"url":"http://x/y","size":3}"#] {
            let mut server = mockito::Server::new_async().await;
            let _m = server
                .mock("PUT", "/upload")
                .with_status(201)
                .with_body(body)
                .create_async()
                .await;
            let keys = Keys::generate();
            let server_url = url::Url::parse(&server.url()).unwrap();
            let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
            let err = upload_with_client(&no_redirect_client(), &keys, &server_url, processed)
                .await
                .expect_err("malformed descriptor rejected");
            assert!(
                matches!(err, ProfileError::Blossom(_)),
                "body {body:?} → {err:?}"
            );
        }
    }

    #[tokio::test]
    async fn upload_rejects_non_https_server() {
        // A public http:// server (not loopback) is rejected before any I/O by
        // the public wrapper's `require_https` gate.
        let keys = Keys::generate();
        let server_url = url::Url::parse("http://blossom.example").unwrap();
        let err = upload_profile_picture(&keys, &server_url, &tiny_jpeg())
            .await
            .expect_err("http server rejected");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    }

    // ---- download core (mockito, via download_with_client) -----------------
    //
    // These exercise the size caps / hash / decode re-validation WITHOUT the
    // anti-SSRF resolver (which would block 127.0.0.1). The SSRF filter itself
    // is covered by the is_forbidden_addr tests + the full-path reject tests.

    #[tokio::test]
    async fn download_rejects_oversize_content_length() {
        // A truthful, well-formed response whose Content-Length exceeds the cap
        // must be rejected by the precheck (before the body is streamed).
        let mut server = mockito::Server::new_async().await;
        let over = usize::try_from(PROFILE_PICTURE_MAX_DOWNLOAD_BYTES).unwrap() + 4096;
        let _m = server
            .mock("GET", "/blob")
            .with_status(200)
            .with_body(vec![0u8; over]) // Content-Length auto-set to `over` > cap
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/blob", server.url())).unwrap();
        let err = download_with_client(&client, &url)
            .await
            .expect_err("oversize content-length rejected");
        assert!(matches!(err, ProfileError::TooLarge), "got {err:?}");
    }

    #[tokio::test]
    async fn download_streams_cap_when_length_lies() {
        // Chunked transfer ⇒ no Content-Length ⇒ the streamed byte counter is
        // the only guard; a body over the cap must be rejected.
        let mut server = mockito::Server::new_async().await;
        let over = usize::try_from(PROFILE_PICTURE_MAX_DOWNLOAD_BYTES).unwrap() + 4096;
        let _m = server
            .mock("GET", "/blob")
            .with_status(200)
            .with_chunked_body(move |w| w.write_all(&vec![0u8; over]))
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/blob", server.url())).unwrap();
        let err = download_with_client(&client, &url)
            .await
            .expect_err("streamed overrun rejected");
        assert!(matches!(err, ProfileError::TooLarge), "got {err:?}");
    }

    #[tokio::test]
    async fn download_sha_mismatch_rejected() {
        // URL commits to a sha that the served bytes do not match.
        let mut server = mockito::Server::new_async().await;
        let wrong_sha = "c".repeat(64);
        let _m = server
            .mock("GET", format!("/{wrong_sha}").as_str())
            .with_status(200)
            .with_body(tiny_jpeg())
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/{wrong_sha}", server.url())).unwrap();
        let err = download_with_client(&client, &url)
            .await
            .expect_err("sha mismatch rejected");
        assert!(matches!(err, ProfileError::HashMismatch), "got {err:?}");
    }

    #[tokio::test]
    async fn download_revalidates_through_inbound_pipeline() {
        // Happy path: URL hash matches the served bytes; the returned picture
        // is re-encoded (canonical/thumbnail from process_inbound_avatar).
        let mut server = mockito::Server::new_async().await;
        let bytes = tiny_jpeg();
        let sha_hex = hex::encode(Sha256::digest(&bytes));
        let _m = server
            .mock("GET", format!("/{sha_hex}").as_str())
            .with_status(200)
            .with_body(bytes)
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/{sha_hex}", server.url())).unwrap();
        let pic = download_with_client(&client, &url)
            .await
            .expect("download + revalidate");
        assert_eq!(
            pic.sha256_hex, sha_hex,
            "sha is over the raw downloaded bytes"
        );
        assert!(!pic.canonical.is_empty());
        assert!(!pic.thumbnail.is_empty());
        // The canonical is a fresh JPEG re-encode.
        assert!(
            pic.canonical.len() >= 3 && pic.canonical[0] == 0xFF && pic.canonical[1] == 0xD8,
            "canonical is a re-encoded JPEG"
        );
    }

    #[tokio::test]
    async fn download_rejects_non_image_bytes() {
        // Bytes that pass the (absent) sha check but are not a valid image must
        // be rejected by the decode-bomb re-validation, not panic.
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/notimage")
            .with_status(200)
            .with_body("this is not an image")
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/notimage", server.url())).unwrap();
        let err = download_with_client(&client, &url)
            .await
            .expect_err("non-image rejected");
        assert!(matches!(err, ProfileError::Image(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn download_500_maps_to_error() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/blob")
            .with_status(500)
            .with_body("boom")
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/blob", server.url())).unwrap();
        let err = download_with_client(&client, &url)
            .await
            .expect_err("500 is an error");
        assert!(matches!(err, ProfileError::Http(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn download_refuses_redirect() {
        // With redirects disabled the 302 is surfaced as a non-success status,
        // never followed to the Location target.
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/blob")
            .with_status(302)
            .with_header("location", "https://evil.example/x")
            .create_async()
            .await;
        let client = no_redirect_client();
        let url = url::Url::parse(&format!("{}/blob", server.url())).unwrap();
        let err = download_with_client(&client, &url)
            .await
            .expect_err("redirect not followed");
        assert!(matches!(err, ProfileError::Http(_)), "got {err:?}");
    }

    // ---- url sha extraction ------------------------------------------------

    #[test]
    fn extract_sha256_from_url_variants() {
        let sha = "d".repeat(64);
        let with_ext = url::Url::parse(&format!("https://h/{sha}.jpg")).unwrap();
        assert_eq!(
            extract_sha256_from_url(&with_ext).as_deref(),
            Some(sha.as_str())
        );
        let bare = url::Url::parse(&format!("https://h/{sha}")).unwrap();
        assert_eq!(
            extract_sha256_from_url(&bare).as_deref(),
            Some(sha.as_str())
        );
        let none = url::Url::parse("https://h/not-a-hash.jpg").unwrap();
        assert_eq!(extract_sha256_from_url(&none), None);
    }

    // ---- LIVE round-trip against the real local-blossom server -------------
    //
    // Gated `#[ignore]` because it needs a running server + the loopback
    // anti-SSRF opt-in. Run against `tooling/e2e/local-blossom`:
    //   HAVEN_E2E_BLOSSOM=http://127.0.0.1:<port> \
    //     cargo test --lib profile::blossom::live_round_trip_against_local_blossom \
    //       -- --ignored --exact --nocapture
    //
    // This is the correctness proof for the fix: local-blossom returns
    // `201 Created` for a fresh blob (BUD-02), which the old 200-only path
    // rejected. A green run proves the hand-rolled PUT accepts 201 end-to-end,
    // then that the uploaded blob downloads + re-validates byte-for-byte.

    #[tokio::test]
    #[ignore = "needs a running Blossom server; set HAVEN_E2E_BLOSSOM=http://127.0.0.1:<port>"]
    async fn live_round_trip_against_local_blossom() {
        let base = std::env::var("HAVEN_E2E_BLOSSOM")
            .expect("set HAVEN_E2E_BLOSSOM to the local-blossom base URL");
        // Relax the anti-SSRF filter for the loopback test server (debug only).
        // Install-once; a sibling opt-in is fine, so ignore an already-set error.
        let _ = allow_private_blossom_for_test();

        let keys = Keys::generate();
        let server_url = url::Url::parse(&base).expect("valid base url");
        let jpeg = tiny_jpeg();

        let pic = upload_profile_picture(&keys, &server_url, &jpeg)
            .await
            .expect("live upload succeeds (server returns 201 for a new blob)");
        assert_eq!(pic.sha256_hex.len(), 64, "sha256 hex present");
        assert!(
            pic.url.contains(&pic.sha256_hex),
            "descriptor url is content-addressed"
        );
        eprintln!("[live] upload OK sha256={} url={}", pic.sha256_hex, pic.url);

        let round = download_profile_picture(&pic.url)
            .await
            .expect("live download + re-validate succeeds");
        assert_eq!(round.sha256_hex, pic.sha256_hex, "round-trip sha matches");
        assert!(!round.canonical.is_empty(), "re-validated canonical bytes");
        eprintln!("[live] round-trip OK for {}", pic.url);
    }
}
