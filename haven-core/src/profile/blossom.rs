//! Blossom (BUD-02/BUD-11) profile-picture upload + anti-SSRF download.
//!
//! Two network operations live here:
//!
//! * [`upload_profile_picture`] — take an already-sanitized [`StagedPicture`]
//!   (the sealed type whose only constructors run, or replay, the avatar
//!   pipeline's EXIF/GPS strip + re-encode) → hand-rolled BUD-02 `PUT /upload`
//!   carrying a BUD-11 kind-24242 authorization signed by the identity key
//!   (10 min expiry) and an `X-SHA-256` header → verify the returned
//!   descriptor: its `sha256` and its URL's content address equal the staged
//!   hash, its `size` (when given) the body's, and its URL is HTTPS on the
//!   server's own site. The servers are tried in order, the next only after
//!   the previous one failed to hand back such a descriptor. The PUT is
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
//!   Name-based checks are insufficient (DNS rebinding), so each request's
//!   [`reqwest::Client`] installs a custom [`reqwest::dns::Resolve`]
//!   ([`SsrfGuardResolver`]): reqwest connects to exactly the addresses the
//!   resolver returns, at every connect of the request, so filtering inside
//!   the resolver gates the real socket target — closing the rebinding window.
//!   A pre-flight resolution ([`preflight_ssrf_check`]) additionally yields a
//!   clean [`ProfileError::InsecureUrl`] before any connection is attempted.
//!   Both share [`is_forbidden_addr`], which rejects loopback, RFC-1918,
//!   link-local (`169.254/16`, `fe80::/10`), ULA (`fc00::/7`), CGNAT
//!   (`100.64/10`), unspecified, multicast, broadcast, documentation
//!   (`2001:db8::/32`) and reserved ranges. Every IPv4-in-IPv6 embedding is
//!   unwrapped and re-checked as IPv4 — IPv4-mapped (`::ffff:0:0/96`),
//!   IPv4-compatible (`::/96`) and NAT64 (`64:ff9b::/96`) — so an embedded
//!   private target cannot bypass it.
//! * **Bounded redirects.** An upload follows none. A download of a
//!   content-addressed URL (a trailing 64-hex segment) follows at most
//!   [`BLOSSOM_MAX_REDIRECTS`] — BUD-01 lets a server redirect a blob, and
//!   Primal always does — each scheme-checked, an IP-literal target vetted here
//!   (the connector never asks the resolver about a literal) and a hostname
//!   vetted by the resolver at its own connect, with no `Referer`. Any other
//!   download follows none. No cookies (the `cookies` feature is not enabled),
//!   generic UA.
//! * **Size cap enforced twice**: a `Content-Length` precheck AND a streamed
//!   byte counter ([`PROFILE_PICTURE_MAX_DOWNLOAD_BYTES`]) that catches a body
//!   overrunning a lying/absent length.
//! * **Integrity + decode-bomb re-validation**: `sha256(raw) ==` the
//!   REQUESTED URL's trailing 64-hex commitment (when present), however many
//!   redirects led to the bytes, then [`process_inbound_avatar`]
//!   re-decodes/re-encodes them.
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
    BlossomAuthEncoding, UploadServer, AVATAR_MIME, BLOSSOM_AUTH_EXPIRY_SECS,
    BLOSSOM_MAX_REDIRECTS, BLOSSOM_TIMEOUT, PROFILE_PICTURE_MAX_DOWNLOAD_BYTES,
};
use super::error::{ProfileError, Result};
use super::types::ProfilePicture;
use crate::avatar::image::{process_inbound_avatar, StagedPicture};

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
/// reqwest connects to exactly the addresses this resolver returns, at every
/// connect a request makes (a followed redirect's included), so filtering
/// here gates the actual connected address and defeats DNS rebinding. An IP
/// literal never reaches it, which is why [`redirect_refusal`] vets one.
/// Resolution fails closed: if any resolved address is forbidden, the whole
/// resolution is rejected.
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

/// How a request's client is built (SSRF-filtered resolver, generic UA,
/// bounded timeouts, no cookies, no idle connection, no `Referer`), following
/// redirects as `redirect` says.
///
/// No `Referer`: a followed redirect would otherwise tell its target which
/// picture URL — and so which host — sent the viewer there.
fn client_builder(redirect: reqwest::redirect::Policy) -> reqwest::ClientBuilder {
    let builder = reqwest::Client::builder()
        .redirect(redirect)
        .referer(false)
        .user_agent("Haven")
        .connect_timeout(BLOSSOM_TIMEOUT)
        .timeout(BLOSSOM_TIMEOUT)
        .pool_max_idle_per_host(0)
        .dns_resolver(Arc::new(SsrfGuardResolver));
    #[cfg(test)]
    let builder = tests::trusting_the_test_root(builder);
    builder
}

/// A client of its own for one upload or download, built for it and dropped
/// with it. Nothing of one request is there for the next: no pooled
/// connection, and no TLS session — rustls keeps resumption tickets in its
/// client config, one per `reqwest::Client`, so a client shared across a
/// logout would present the previous identity's ticket to the same host,
/// which could link the two. The cost is one full handshake per request;
/// avatars are cached and uploads are rare.
///
/// An upload follows no redirect: one would carry the identity-signed token
/// and the body to a host nobody chose (and a `302` may replay the `PUT` as a
/// `GET`), so a `3xx` is that server's failure.
fn upload_client() -> Result<reqwest::Client> {
    client_builder(reqwest::redirect::Policy::none())
        .build()
        .map_err(ProfileError::http)
}

/// The client of one picture download (see [`upload_client`] for why one per
/// request). It follows redirects only for a content-addressed URL, whose
/// bytes the final hash check binds wherever they come from.
fn download_client(content_addressed: bool) -> Result<reqwest::Client> {
    let redirect = if content_addressed {
        reqwest::redirect::Policy::custom(|attempt| {
            match redirect_refusal(attempt.url(), attempt.previous().len()) {
                None => attempt.follow(),
                Some(refused) => attempt.error(refused),
            }
        })
    } else {
        reqwest::redirect::Policy::none()
    };
    client_builder(redirect).build().map_err(ProfileError::http)
}

/// Why a picture download's redirect is not followed. Fieldless, so neither
/// rendering can carry the refused target (Security Rule 15).
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
enum RedirectRefused {
    /// More than [`BLOSSOM_MAX_REDIRECTS`] redirects.
    #[error("too many redirects")]
    Hops,
    /// The target is not HTTPS (outside the debug loopback allowance).
    #[error("redirect to an insecure scheme")]
    Scheme,
    /// The target is an IP literal the anti-SSRF filter forbids.
    #[error("redirect to a forbidden address")]
    Address,
}

/// Whether the `hop`-th redirect of a download, to `next`, is refused.
///
/// The target need not carry the requested sha256. BUD-01 obliges a server to
/// redirect only to one that does, but Primal's `GET /<sha256>` may answer
/// with any stored copy of the bytes, some of them key-addressed; integrity
/// is the final body's hash against the REQUESTED URL's address, which a hop
/// cannot change. A hostname is left to [`SsrfGuardResolver`] at its connect.
fn redirect_refusal(next: &url::Url, hop: usize) -> Option<RedirectRefused> {
    if hop > BLOSSOM_MAX_REDIRECTS {
        return Some(RedirectRefused::Hops);
    }
    if require_https(next).is_err() {
        return Some(RedirectRefused::Scheme);
    }
    let literal = match next.host() {
        Some(url::Host::Ipv4(v4)) => IpAddr::V4(v4),
        Some(url::Host::Ipv6(v6)) => IpAddr::V6(v6),
        _ => return None,
    };
    (!addr_permitted(literal)).then_some(RedirectRefused::Address)
}

/// The error a download's failed `send` maps to: a refused redirect by its
/// kind, wherever reqwest nested it, anything else as transport.
fn send_error(e: &reqwest::Error) -> ProfileError {
    let refused = std::iter::successors(std::error::Error::source(e), |s| s.source())
        .find_map(|s| s.downcast_ref::<RedirectRefused>().copied());
    match refused {
        Some(RedirectRefused::Hops) => ProfileError::http("redirect limit"),
        Some(RedirectRefused::Scheme | RedirectRefused::Address) => ProfileError::InsecureUrl,
        None => ProfileError::http(e),
    }
}

// ===========================================================================
// Upload
// ===========================================================================

/// The kind of a BUD-11 Blossom authorization event (`24242`).
const BLOSSOM_AUTH_KIND: u16 = 24242;

/// A BUD-02 blob descriptor as returned by `PUT /upload` / `GET /list`.
///
/// `url`, `sha256` and `size` are re-verified against our own bytes; `type` /
/// `uploaded` are ignored by the deserializer. The two required fields being
/// non-`Option` means a malformed or `sha256`-less body fails to parse and is
/// surfaced as an error (never a silent accept).
#[derive(serde::Deserialize)]
struct BlobDescriptor {
    /// The public URL at which the blob can be fetched.
    url: String,
    /// Lowercase hex sha256 the server computed over the stored bytes.
    sha256: String,
    /// The stored size in bytes, when the server reports it.
    size: Option<u64>,
}

/// Builds the `Authorization: Nostr <base64>` header value carrying a signed
/// BUD-11 kind-24242 upload authorization for the blob whose sha256 hex is
/// `sha256_hex`, base64-encoded as `encoding` says.
///
/// The event carries `["t","upload"]`, `["expiration", now + 10 min]` and
/// `["x", <sha256_hex>]`, a short human-readable `content`, and `created_at =
/// now`, signed by the identity `keys`.
///
/// # Errors
///
/// [`ProfileError::Build`] if event signing fails.
fn build_upload_auth_header(
    keys: &Keys,
    sha256_hex: &str,
    encoding: BlossomAuthEncoding,
) -> Result<String> {
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
    Ok(format!(
        "Nostr {}",
        encode_token(encoding, &event.as_json())
    ))
}

/// `json` base64-encoded as `encoding` says.
fn encode_token(encoding: BlossomAuthEncoding, json: &str) -> String {
    match encoding {
        BlossomAuthEncoding::PaddedStandard => {
            base64::engine::general_purpose::STANDARD.encode(json)
        }
        BlossomAuthEncoding::UrlSafeUnpadded => {
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)
        }
    }
}

/// Uploads an already-sanitized profile picture to the first of `servers`
/// that takes it, and returns the resolved [`ProfilePicture`].
///
/// Each server in turn: [`require_https`] → hand-rolled BUD-02 `PUT /upload`
/// (a fresh identity-signed BUD-11 kind-24242 auth in that server's encoding,
/// `X-SHA-256`) under [`BLOSSOM_TIMEOUT`] → verify the descriptor. The next
/// server is tried after ANY failure to obtain a verified descriptor — a
/// non-2xx (a redirect included), a timeout, a transport error, a descriptor
/// that does not verify — so a server that timed out may hold the bytes too:
/// the photo can end up on more than one server. The same bytes, and so the
/// same content address, go to every server.
///
/// Sanitization is not performed here and is not optional: [`StagedPicture`]
/// can only be built from the avatar pipeline's output (or from bytes it
/// previously produced, whose hash is then recomputed), so the bytes that reach
/// the wire are EXIF/GPS-stripped and re-encoded by construction, and the hash
/// always commits to exactly what is uploaded. Nothing here re-encodes, so the
/// staged hash is the blob's Blossom content address.
///
/// # Errors
///
/// The last server's failure: [`ProfileError::InsecureUrl`] (a non-HTTPS
/// server, or a descriptor URL off HTTPS or off the server's site),
/// [`ProfileError::HashMismatch`] (a descriptor whose hash or URL address
/// disagrees), [`ProfileError::Timeout`] / [`ProfileError::Blossom`] /
/// [`ProfileError::Http`]. [`ProfileError::Build`] at once if signing fails,
/// which no other server would change; [`ProfileError::NoRelays`] for an empty
/// list.
pub async fn upload_profile_picture(
    keys: &Keys,
    servers: &[UploadServer],
    staged: StagedPicture,
) -> Result<ProfilePicture> {
    let client = upload_client()?;
    let mut failure = ProfileError::NoRelays;
    for server in servers {
        match upload_once(&client, keys, server, &staged).await {
            Ok(url) => {
                let sha256_hex = hex::encode(staged.sha256());
                let (canonical, thumbnail) = staged.into_render_bytes();
                return Ok(ProfilePicture {
                    url,
                    sha256_hex,
                    canonical,
                    thumbnail,
                });
            }
            Err(e @ ProfileError::Build(_)) => return Err(e),
            Err(e) => {
                // Which server is not said: the list is public, so its
                // position names a host (Security Rule 15).
                log::debug!("[profile] picture upload: a server failed ({})", e.code());
                failure = e;
            }
        }
    }
    Err(failure)
}

/// One `PUT /upload` to `server`, returning the verified descriptor URL.
///
/// # Errors
///
/// As [`upload_profile_picture`], for this one server.
async fn upload_once(
    client: &reqwest::Client,
    keys: &Keys,
    server: &UploadServer,
    staged: &StagedPicture,
) -> Result<String> {
    require_https(&server.base)?;
    let expected_hex = hex::encode(staged.sha256());
    let upload_url = server
        .base
        .join("upload")
        .map_err(|_| ProfileError::BadUrl)?;
    let auth_header = build_upload_auth_header(keys, &expected_hex, server.auth)?;

    let response = tokio::time::timeout(
        BLOSSOM_TIMEOUT,
        client
            .put(upload_url)
            .header(reqwest::header::AUTHORIZATION, auth_header)
            .header(reqwest::header::CONTENT_TYPE, AVATAR_MIME)
            .header("X-SHA-256", &expected_hex)
            .body(staged.canonical().to_vec())
            .send(),
    )
    .await
    .map_err(|_| ProfileError::Timeout)?
    .map_err(ProfileError::http)?;

    // BUD-02: `201 Created` for a new blob, `200 OK` for an already-present one;
    // accept any 2xx, reject everything else. The class alone is logged: the
    // `X-Reason` and the body are server-authored.
    let status = response.status();
    if !status.is_success() {
        log::debug!(
            "[profile] picture upload: status {}xx",
            status.as_u16() / 100
        );
        return Err(ProfileError::blossom(format!("upload status {status}")));
    }

    let body = read_body_capped(response, PROFILE_PICTURE_MAX_DOWNLOAD_BYTES).await?;
    let descriptor: BlobDescriptor =
        serde_json::from_slice(&body).map_err(ProfileError::blossom)?;

    // The URL the server hands back is where members will fetch, so it must be
    // HTTPS too, and must carry our hash: a peer checks a download's bytes
    // only against the address its URL carries.
    let descriptor_url = url::Url::parse(&descriptor.url).map_err(|_| ProfileError::BadUrl)?;
    require_https(&descriptor_url)?;
    if !descriptor.sha256.eq_ignore_ascii_case(&expected_hex)
        || extract_sha256_from_url(&descriptor_url).as_deref() != Some(expected_hex.as_str())
    {
        return Err(ProfileError::HashMismatch);
    }
    if descriptor
        .size
        .is_some_and(|size| usize::try_from(size).ok() != Some(staged.canonical().len()))
    {
        return Err(ProfileError::blossom("descriptor size"));
    }
    if !on_site(&descriptor_url, &server.site) {
        return Err(ProfileError::InsecureUrl);
    }
    Ok(descriptor.url)
}

/// Whether `url`'s host is `site` or a subdomain of it.
fn on_site(url: &url::Url, site: &str) -> bool {
    url.host_str().is_some_and(|host| {
        host == site
            || host
                .strip_suffix(site)
                .is_some_and(|label| label.ends_with('.'))
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
/// * [`ProfileError::InsecureUrl`] if the URL, or a redirect's target, is not
///   HTTPS or is (or resolves to) a forbidden (loopback/private/…) address.
/// * [`ProfileError::TooLarge`] on a `Content-Length` or streamed-size overrun.
/// * [`ProfileError::HashMismatch`] if the bytes disagree with the URL hash.
/// * [`ProfileError::Http`] / [`ProfileError::Timeout`] on transport failure.
/// * [`ProfileError::Image`] if the bytes fail decode-bomb re-validation.
pub async fn download_profile_picture(url: &str) -> Result<ProfilePicture> {
    let result = async {
        let parsed = url::Url::parse(url).map_err(|_| ProfileError::BadUrl)?;
        require_https(&parsed)?;
        // Pre-flight resolution + filter: fail fast with a clean InsecureUrl.
        preflight_ssrf_check(&parsed).await?;
        // The client's resolver re-filters at connect time (anti-rebinding).
        let client = download_client(extract_sha256_from_url(&parsed).is_some())?;
        download_with_client(&client, &parsed).await
    }
    .await;
    if let Err(e) = &result {
        log::debug!("[profile] picture download failed ({})", e.code());
    }
    result
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
/// has already been scheme- and SSRF-vetted by the caller. The hash is checked
/// against `url`, the one requested, wherever a redirect fetched the bytes.
///
/// # Errors
///
/// As [`download_profile_picture`] (minus the URL-parse / SSRF pre-flight the
/// caller performs).
async fn download_with_client(client: &reqwest::Client, url: &url::Url) -> Result<ProfilePicture> {
    let response = tokio::time::timeout(BLOSSOM_TIMEOUT, client.get(url.clone()).send())
        .await
        .map_err(|_| ProfileError::Timeout)?
        .map_err(|e| send_error(&e))?;

    let status = response.status();
    if !status.is_success() {
        log::debug!(
            "[profile] picture download: status {}xx",
            status.as_u16() / 100
        );
        return Err(ProfileError::http(format!("status {status}")));
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
    #![allow(clippy::significant_drop_tightening)]

    use super::*;

    /// A self-signed certificate for 127.0.0.1 and its PKCS#8 key, made
    /// once per test process and trusted by no client outside this module's
    /// tests. Made at run time so that no private key is committed.
    fn test_tls() -> &'static (Vec<u8>, Vec<u8>) {
        static TLS: std::sync::OnceLock<(Vec<u8>, Vec<u8>)> = std::sync::OnceLock::new();
        TLS.get_or_init(|| {
            use ring::signature::{EcdsaKeyPair, KeyPair as _, ECDSA_P256_SHA256_ASN1_SIGNING};
            let rng = ring::rand::SystemRandom::new();
            let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng)
                .expect("a test key");
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng)
                    .expect("the test key loads");
            let tlv = |tag: u8, body: &[u8]| -> Vec<u8> {
                let mut out = vec![tag];
                match u8::try_from(body.len()) {
                    Ok(len) if len < 0x80 => out.push(len),
                    Ok(len) => out.extend([0x81, len]),
                    Err(_) => {
                        let len = u16::try_from(body.len()).expect("a short field");
                        out.push(0x82);
                        out.extend(len.to_be_bytes());
                    }
                }
                out.extend_from_slice(body);
                out
            };
            let seq = |parts: &[Vec<u8>]| tlv(0x30, &parts.concat());
            let ecdsa_sha256 = seq(&[tlv(0x06, &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])]);
            let name = seq(&[tlv(
                0x31,
                &seq(&[
                    tlv(0x06, &[0x55, 0x04, 0x03]),
                    tlv(0x0c, b"haven-blossom-test"),
                ]),
            )]);
            let spki = seq(&[
                seq(&[
                    tlv(0x06, &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]),
                    tlv(0x06, &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]),
                ]),
                tlv(0x03, &[&[0][..], pair.public_key().as_ref()].concat()),
            ]);
            let loopback_san = seq(&[seq(&[
                tlv(0x06, &[0x55, 0x1d, 0x11]),
                tlv(0x04, &seq(&[tlv(0x87, &[127, 0, 0, 1])])),
            ])]);
            let tbs = seq(&[
                tlv(0xa0, &tlv(0x02, &[2])),
                tlv(0x02, &[1]),
                ecdsa_sha256.clone(),
                name.clone(),
                seq(&[tlv(0x17, b"200101000000Z"), tlv(0x18, b"21000101000000Z")]),
                name,
                spki,
                tlv(0xa3, &loopback_san),
            ]);
            let signature = pair
                .sign(&rng, &tbs)
                .expect("the test certificate is signed");
            let certificate = seq(&[
                tbs,
                ecdsa_sha256,
                tlv(0x03, &[&[0][..], signature.as_ref()].concat()),
            ]);
            (certificate, pkcs8.as_ref().to_vec())
        })
    }

    /// Whether this test process trusts [`test_tls`]'s certificate: set only
    /// by the TLS test.
    static TRUST_TEST_ROOT: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);

    /// The request client of a test process that trusts the test certificate
    /// as well.
    pub(super) fn trusting_the_test_root(
        builder: reqwest::ClientBuilder,
    ) -> reqwest::ClientBuilder {
        if TRUST_TEST_ROOT.load(std::sync::atomic::Ordering::SeqCst) {
            builder.add_root_certificate(
                reqwest::Certificate::from_der(&test_tls().0).expect("the test certificate parses"),
            )
        } else {
            builder
        }
    }

    /// No TLS session of one Blossom request is resumed by the next: two
    /// requests in a row to one host each make a FULL handshake, as the server
    /// that issued them tickets sees it. What a logout leaves behind cannot
    /// carry the previous identity's session to the next identity's request.
    #[tokio::test]
    async fn no_tls_session_outlives_its_request() {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        TRUST_TEST_ROOT.store(true, std::sync::atomic::Ordering::SeqCst);
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let (certificate, pkcs8) = test_tls();
        let certs = vec![rustls::pki_types::CertificateDer::from(certificate.clone())];
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
            rustls::pki_types::PrivatePkcs8KeyDer::from(pkcs8.clone()),
        );
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("protocol versions")
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .expect("the server certificate");
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let kinds = Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = Arc::clone(&kinds);
        let server = tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else {
                    return;
                };
                let (acceptor, seen) = (acceptor.clone(), Arc::clone(&seen));
                tokio::spawn(async move {
                    let Ok(mut tls) = acceptor.accept(socket).await else {
                        return;
                    };
                    seen.lock()
                        .expect("kinds")
                        .push(tls.get_ref().1.handshake_kind());
                    let mut request = [0_u8; 1024];
                    if tls.read(&mut request).await.is_ok_and(|read| read > 0) {
                        let _ = tls
                            .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
                            .await;
                        let _ = tls.shutdown().await;
                    }
                });
            }
        });
        for _ in 0..2 {
            let body = upload_client()
                .expect("the client builds")
                .get(format!("https://{address}/"))
                .send()
                .await
                .expect("answered")
                .bytes()
                .await
                .expect("read");
            assert_eq!(&body[..], b"ok");
        }
        server.abort();
        assert_eq!(
            *kinds.lock().expect("kinds"),
            [
                Some(rustls::HandshakeKind::Full),
                Some(rustls::HandshakeKind::Full)
            ],
            "a request resumed the TLS session an earlier request opened",
        );
    }

    /// No connection of the shared client outlives its request: two requests
    /// to one host in a row open two connections, so nothing one identity
    /// opened carries the next one's traffic after a logout. Counted at the
    /// server, an IP literal on loopback (the resolver is never asked).
    #[tokio::test]
    async fn no_connection_outlives_its_request() {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let address = listener.local_addr().expect("address");
        let accepted = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = Arc::clone(&accepted);
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    return;
                };
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut request = [0_u8; 1024];
                    // A connection kept alive answers every request on it.
                    while socket.read(&mut request).await.is_ok_and(|read| read > 0) {
                        let answered = socket
                            .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
                            .await;
                        if answered.is_err() {
                            return;
                        }
                    }
                });
            }
        });
        let client = client_builder(reqwest::redirect::Policy::none())
            .build()
            .expect("the client builds");
        for _ in 0..2 {
            let body = client
                .get(format!("http://{address}/"))
                .send()
                .await
                .expect("answered")
                .bytes()
                .await
                .expect("read");
            assert_eq!(&body[..], b"ok");
        }
        server.abort();
        assert_eq!(
            accepted.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "a request rode a connection an earlier request left open",
        );
    }

    // A mockito `Server` (and its mock guards) must live for the whole test so
    // the async HTTP round-trips can reach it; `significant_drop_tightening`'s
    // "drop earlier" suggestion is a false positive here.
    use crate::avatar::image::process_own_avatar;
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

    /// Runs `raw` through the sanitizer and seals the result for upload — the
    /// only way to obtain upload bytes, in tests as in production.
    fn staged(raw: &[u8]) -> StagedPicture {
        StagedPicture::from_processed(&process_own_avatar(raw).expect("pipeline"))
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
        // Exercises every client construction (with the SSRF resolver)
        // without any network I/O.
        assert!(upload_client().is_ok());
        assert!(download_client(true).is_ok());
        assert!(download_client(false).is_ok());
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
    // These drive the public `upload_profile_picture` against loopback mocks:
    // a mock's `http://127.0.0.1` base passes `require_https` in debug, and an
    // IP literal never reaches the SSRF resolver.

    /// A mock as an upload server whose site is its own host.
    fn at(server: &mockito::ServerGuard, auth: BlossomAuthEncoding) -> UploadServer {
        let base = url::Url::parse(&server.url()).expect("mock url");
        UploadServer {
            site: base.host_str().expect("mock host").to_string(),
            base,
            auth,
        }
    }

    fn primal_like(server: &mockito::ServerGuard) -> UploadServer {
        at(server, BlossomAuthEncoding::PaddedStandard)
    }

    /// A loopback base that refuses every connection.
    fn dead_server() -> UploadServer {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("address").port();
        drop(listener);
        let base = url::Url::parse(&format!("http://127.0.0.1:{port}")).expect("url");
        UploadServer {
            base,
            site: "127.0.0.1".to_string(),
            auth: BlossomAuthEncoding::PaddedStandard,
        }
    }

    /// Answers `PUT /upload` with `status` and, for a 2xx, the descriptor of
    /// `processed`'s bytes at this server, `hits` times.
    async fn answering(
        server: &mut mockito::ServerGuard,
        processed: &crate::avatar::image::ProcessedAvatar,
        status: usize,
        hits: usize,
    ) -> mockito::Mock {
        let sha_hex = hex::encode(processed.content_hash);
        let body = descriptor_json(&server.url(), &sha_hex, processed.canonical.len());
        server
            .mock("PUT", "/upload")
            .with_status(status)
            .with_body(if (200..300).contains(&status) {
                body
            } else {
                String::new()
            })
            .expect(hits)
            .create_async()
            .await
    }

    /// Runs the upload happy path against a mock returning `status`, asserting
    /// the fully-resolved [`ProfilePicture`]. Parameterized so both the BUD-02
    /// `201 Created` (new blob) and `200 OK` (existing blob) responses are
    /// proven to succeed — the core of the 200-only foot-gun fix.
    async fn upload_happy_path_with_status(status: usize) {
        let mut server = mockito::Server::new_async().await;
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);
        let _m = answering(&mut server, &processed, status, 1).await;

        let pic = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&server)],
            StagedPicture::from_processed(&processed),
        )
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
        let _m = answering(&mut server, &processed, 201, 1).await;

        let pic = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&server)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("upload");
        assert_eq!(
            pic.sha256_hex, sha_hex,
            "reported hash is the sanitized one"
        );
    }

    /// What a mock received for one `PUT /upload`.
    struct SentUpload {
        header: std::collections::HashMap<String, String>,
        body: Vec<u8>,
    }

    impl SentUpload {
        fn header(&self, name: &str) -> Option<&str> {
            self.header.get(name).map(String::as_str)
        }

        /// The `Nostr <base64>` token, base64 still encoded.
        fn token(&self) -> &str {
            self.header("authorization")
                .and_then(|h| h.strip_prefix("Nostr "))
                .expect("header uses the `Nostr <base64>` scheme")
        }
    }

    /// The request one upload to a server sending its token in `auth` made.
    async fn captured_upload(
        auth: BlossomAuthEncoding,
    ) -> (Keys, crate::avatar::image::ProcessedAvatar, SentUpload) {
        let mut server = mockito::Server::new_async().await;
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let captured: Arc<std::sync::Mutex<Option<SentUpload>>> =
            Arc::new(std::sync::Mutex::new(None));
        let cap = Arc::clone(&captured);
        let sha_hex = hex::encode(processed.content_hash);
        let _m = server
            .mock("PUT", "/upload")
            .match_request(move |req| {
                let header = ["authorization", "x-sha-256", "content-length"]
                    .into_iter()
                    .filter_map(|name| {
                        let value = req.header(name).first()?.to_str().ok()?.to_string();
                        Some((name.to_string(), value))
                    })
                    .collect();
                let body = req.body().cloned().unwrap_or_default();
                *cap.lock().unwrap() = Some(SentUpload { header, body });
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
        upload_profile_picture(
            &keys,
            &[at(&server, auth)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("upload");
        let sent = captured
            .lock()
            .unwrap()
            .take()
            .expect("the mock saw the request");
        (keys, processed, sent)
    }

    /// Asserts `decoded` is a verifying kind-24242 upload authorization by
    /// `keys` for `sha_hex`, expiring ten minutes after it was signed.
    fn assert_upload_auth(decoded: &[u8], keys: &Keys, sha_hex: &str) {
        let event: nostr::Event =
            serde_json::from_slice(decoded).expect("auth payload is a nostr event");
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
        let tag = |name: &str| {
            event
                .tags
                .iter()
                .map(nostr::Tag::as_slice)
                .find(|s| s.len() >= 2 && s[0] == name)
                .map(|s| s[1].clone())
        };
        assert_eq!(tag("t").as_deref(), Some("upload"), "{:?}", event.tags);
        assert_eq!(
            tag("x").as_deref(),
            Some(sha_hex),
            "auth carries x = sanitized-bytes hash"
        );
        let expiration: u64 = tag("expiration")
            .expect("an expiration tag")
            .parse()
            .expect("a number");
        assert_eq!(
            expiration - event.created_at.as_secs(),
            BLOSSOM_AUTH_EXPIRY_SECS,
            "the token tolerates ten minutes of clock skew",
        );
        assert_eq!(BLOSSOM_AUTH_EXPIRY_SECS, 600);
    }

    #[tokio::test]
    async fn upload_sends_the_exact_staged_bytes_its_hash_header_and_length() {
        // The upload re-encodes NOTHING. That is what makes the cached content
        // hash equal the blob's Blossom address: the hash in the BUD-11
        // authorization, the hash the descriptor is checked against, and the
        // hash of what the local cache holds are all the same number because
        // they all commit to these exact bytes. Re-encoding here (however
        // faithfully) would break that identity silently — the server would
        // store a blob at a different address than the one we authorized.
        let (_keys, processed, request) =
            captured_upload(BlossomAuthEncoding::PaddedStandard).await;
        let sent = request.body.clone();
        assert_eq!(
            sent,
            processed.canonical.to_vec(),
            "the PUT body must be the staged canonical bytes, byte for byte",
        );
        let sha_hex = hex::encode(processed.content_hash);
        assert_eq!(
            hex::encode(Sha256::digest(&sent)),
            sha_hex,
            "so the address the server stores the blob at is the staged hash",
        );
        assert_eq!(
            request.header("x-sha-256"),
            Some(sha_hex.as_str()),
            "BUD-11 ties the token's `x` to this header on PUT /upload",
        );
        assert_eq!(
            request.header("content-length"),
            Some(sent.len().to_string().as_str()),
            "a streamed body would drop the length some servers require",
        );
    }

    #[tokio::test]
    async fn upload_auth_header_is_standard_base64_24242_event() {
        // Primal's server decodes padded STANDARD base64 only.
        let (keys, processed, request) = captured_upload(BlossomAuthEncoding::PaddedStandard).await;
        let b64 = request.token();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .expect("auth header is standard padded base64");
        assert!(
            base64::engine::general_purpose::STANDARD.encode(&decoded) == b64,
            "the token is exactly the padded standard encoding of its event",
        );
        assert_upload_auth(&decoded, &keys, &hex::encode(processed.content_hash));
    }

    #[tokio::test]
    async fn upload_auth_header_for_an_unpadded_server_is_base64url() {
        let (keys, processed, request) =
            captured_upload(BlossomAuthEncoding::UrlSafeUnpadded).await;
        let b64 = request.token();
        let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(b64)
            .expect("auth header is unpadded base64url");
        assert!(
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&decoded) == b64,
            "the token is exactly the unpadded base64url encoding of its event",
        );
        assert_upload_auth(&decoded, &keys, &hex::encode(processed.content_hash));
    }

    #[test]
    fn each_encoding_is_the_one_its_server_decodes() {
        // An input that needs padding and maps onto both alphabet-specific
        // characters, which a token's own JSON may happen not to.
        assert_eq!(
            encode_token(BlossomAuthEncoding::PaddedStandard, ">>>?"),
            "Pj4+Pw=="
        );
        assert_eq!(
            encode_token(BlossomAuthEncoding::UrlSafeUnpadded, ">>>?"),
            "Pj4-Pw"
        );
        assert_eq!(
            encode_token(BlossomAuthEncoding::PaddedStandard, "??"),
            "Pz8="
        );
        assert_eq!(
            encode_token(BlossomAuthEncoding::UrlSafeUnpadded, "??"),
            "Pz8"
        );
        assert_eq!(
            encode_token(BlossomAuthEncoding::UrlSafeUnpadded, "\u{ff}?"),
            "w78_"
        );
    }

    /// Uploads `tiny_jpeg` to a mock answering one `PUT /upload` with
    /// `status` and `body`, and returns the error.
    async fn upload_answered(
        status: usize,
        body: impl FnOnce(&str, &str, usize) -> String,
    ) -> ProfileError {
        let mut server = mockito::Server::new_async().await;
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);
        let _m = server
            .mock("PUT", "/upload")
            .with_status(status)
            .with_body(body(&server.url(), &sha_hex, processed.canonical.len()))
            .create_async()
            .await;
        upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&server)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect_err("the upload must be refused")
    }

    #[tokio::test]
    async fn upload_500_maps_to_error_not_panic() {
        let err = upload_answered(500, |_, _, _| "boom".to_string()).await;
        assert!(matches!(err, ProfileError::Blossom(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_4xx_maps_to_error_not_panic() {
        // A 4xx (e.g. 401 auth rejected) is non-2xx → error, never a panic.
        let err = upload_answered(401, |_, _, _| "unauthorized".to_string()).await;
        assert!(matches!(err, ProfileError::Blossom(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_descriptor_hash_mismatch_rejected() {
        // Server echoes a DIFFERENT sha than the uploaded bytes → HashMismatch.
        let err = upload_answered(201, |base, _, size| {
            descriptor_json(base, &"0".repeat(64), size)
        })
        .await;
        assert!(matches!(err, ProfileError::HashMismatch), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_rejects_a_descriptor_url_without_our_hash() {
        // A peer checks a download only against the address its URL carries:
        // a URL with none would publish a picture nobody's download verifies.
        let err = upload_answered(201, |base, sha, size| {
            format!(r#"{{"url":"{base}/avatar.jpg","sha256":"{sha}","size":{size}}}"#)
        })
        .await;
        assert!(matches!(err, ProfileError::HashMismatch), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_rejects_a_descriptor_whose_size_disagrees() {
        let err =
            upload_answered(201, |base, sha, size| descriptor_json(base, sha, size + 1)).await;
        assert!(matches!(err, ProfileError::Blossom(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_rejects_a_descriptor_on_another_site() {
        let err = upload_answered(201, |_, sha, size| {
            descriptor_json("https://elsewhere.example", sha, size)
        })
        .await;
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_accepts_a_descriptor_on_a_subdomain_of_its_site() {
        // Primal uploads on blossom.primal.net and may name media.primal.net.
        let mut server = mockito::Server::new_async().await;
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);
        let _m = server
            .mock("PUT", "/upload")
            .with_status(201)
            .with_body(descriptor_json(
                "https://media.example.net/uploads",
                &sha_hex,
                processed.canonical.len(),
            ))
            .create_async()
            .await;
        let server = UploadServer {
            site: "example.net".to_string(),
            ..primal_like(&server)
        };
        let pic = upload_profile_picture(
            &Keys::generate(),
            &[server],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("a subdomain of the server's site is its own");
        assert_eq!(
            pic.url,
            format!("https://media.example.net/uploads/{sha_hex}")
        );
    }

    #[test]
    fn a_descriptor_host_is_on_site_only_as_the_site_or_a_subdomain() {
        let on = |url: &str| on_site(&url::Url::parse(url).unwrap(), "example.net");
        assert!(on("https://example.net/x"));
        assert!(on("https://media.example.net/x"));
        assert!(on("https://a.b.example.net/x"));
        assert!(!on("https://evilexample.net/x"));
        assert!(!on("https://example.net.evil.test/x"));
        assert!(!on("https://net/x"));
    }

    #[tokio::test]
    async fn upload_rejects_malformed_descriptor() {
        // A 2xx body that is not a valid BUD-02 descriptor — non-JSON, or a JSON
        // object missing the required `sha256` — must be a Blossom error, never
        // a silent accept or a panic.
        for body in ["not a json body", r#"{"url":"http://x/y","size":3}"#] {
            let err = upload_answered(201, |_, _, _| body.to_string()).await;
            assert!(
                matches!(err, ProfileError::Blossom(_)),
                "body {body:?} → {err:?}"
            );
        }
    }

    #[tokio::test]
    async fn upload_rejects_non_https_server() {
        // A public http:// server (not loopback) is rejected before any I/O.
        let server = UploadServer {
            base: url::Url::parse("http://blossom.example").unwrap(),
            site: "blossom.example".to_string(),
            auth: BlossomAuthEncoding::PaddedStandard,
        };
        let err = upload_profile_picture(&Keys::generate(), &[server], staged(&tiny_jpeg()))
            .await
            .expect_err("http server rejected");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_does_not_follow_a_redirect() {
        // A redirect would carry the identity-signed token and the body to a
        // host nobody chose; it is that server's failure, and the next one is
        // asked.
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let mut target = mockito::Server::new_async().await;
        let never = target
            .mock("PUT", "/upload")
            .with_status(201)
            .expect(0)
            .create_async()
            .await;
        let mut redirecting = mockito::Server::new_async().await;
        let _r = redirecting
            .mock("PUT", "/upload")
            .with_status(307)
            .with_header("location", &format!("{}/upload", target.url()))
            .create_async()
            .await;
        let mut next = mockito::Server::new_async().await;
        let took = answering(&mut next, &processed, 201, 1).await;

        let pic = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&redirecting), primal_like(&next)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("the next server takes it");
        assert!(pic.url.starts_with(&next.url()));
        never.assert_async().await;
        took.assert_async().await;
    }

    #[tokio::test]
    async fn upload_falls_back_to_the_next_server_only_after_a_failure() {
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");

        let mut first = mockito::Server::new_async().await;
        let mut second = mockito::Server::new_async().await;
        let refused = answering(&mut first, &processed, 500, 1).await;
        let took = answering(&mut second, &processed, 201, 1).await;
        let pic = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&first), primal_like(&second)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("the second server takes it");
        assert!(pic.url.starts_with(&second.url()), "{}", pic.url);
        refused.assert_async().await;
        took.assert_async().await;

        let mut first = mockito::Server::new_async().await;
        let mut second = mockito::Server::new_async().await;
        let took = answering(&mut first, &processed, 201, 1).await;
        let unasked = answering(&mut second, &processed, 201, 0).await;
        let pic = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&first), primal_like(&second)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("the first server takes it");
        assert!(pic.url.starts_with(&first.url()), "{}", pic.url);
        took.assert_async().await;
        unasked.assert_async().await;
    }

    #[tokio::test]
    async fn upload_falls_back_after_a_descriptor_that_does_not_match() {
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let mut first = mockito::Server::new_async().await;
        let lying = first
            .mock("PUT", "/upload")
            .with_status(200)
            .with_body(descriptor_json(&first.url(), &"0".repeat(64), 1))
            .expect(1)
            .create_async()
            .await;
        let mut second = mockito::Server::new_async().await;
        let took = answering(&mut second, &processed, 201, 1).await;
        let pic = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&first), primal_like(&second)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("the second server takes it");
        assert!(pic.url.starts_with(&second.url()), "{}", pic.url);
        lying.assert_async().await;
        took.assert_async().await;
    }

    #[tokio::test]
    async fn upload_falls_back_when_a_server_refuses_the_connection() {
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let mut second = mockito::Server::new_async().await;
        let took = answering(&mut second, &processed, 201, 1).await;
        let pic = upload_profile_picture(
            &Keys::generate(),
            &[dead_server(), primal_like(&second)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect("the second server takes it");
        assert!(pic.url.starts_with(&second.url()), "{}", pic.url);
        took.assert_async().await;
    }

    #[tokio::test]
    async fn upload_reports_the_last_failure_when_every_server_fails() {
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let mut refusing = mockito::Server::new_async().await;
        let refused = answering(&mut refusing, &processed, 401, 2).await;

        let err = upload_profile_picture(
            &Keys::generate(),
            &[dead_server(), primal_like(&refusing)],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect_err("no server took it");
        assert!(matches!(err, ProfileError::Blossom(_)), "got {err:?}");

        let err = upload_profile_picture(
            &Keys::generate(),
            &[primal_like(&refusing), dead_server()],
            StagedPicture::from_processed(&processed),
        )
        .await
        .expect_err("no server took it");
        assert!(matches!(err, ProfileError::Http(_)), "got {err:?}");
        refused.assert_async().await;
    }

    #[tokio::test]
    async fn a_failed_upload_logs_its_kind_and_status_class_but_no_identifier() {
        let processed = process_own_avatar(&tiny_jpeg()).expect("pipeline");
        let sha_hex = hex::encode(processed.content_hash);
        let keys = Keys::generate();
        let pubkey_hex = keys.public_key().to_hex();
        let npub = nostr::ToBech32::to_bech32(&keys.public_key()).expect("npub");
        let reason = format!("blocked {npub} {sha_hex} see blossom-reason.example");
        let mut refusing = mockito::Server::new_async().await;
        let _m = refusing
            .mock("PUT", "/upload")
            .with_status(401)
            .with_header("x-reason", &reason)
            .with_body(&reason)
            .create_async()
            .await;
        let dead = dead_server();
        let dead_url = dead.base.to_string();
        let servers = [primal_like(&refusing), dead];

        let lines = crate::test_log::capture_log_lines(async {
            upload_profile_picture(&keys, &servers, StagedPicture::from_processed(&processed))
                .await
                .expect_err("no server took it");
        })
        .await;

        // Exactly these lines, in this order: no server position, no digit
        // but the status class.
        assert_eq!(
            lines,
            [
                "[profile] picture upload: status 4xx",
                "[profile] picture upload: a server failed (blossom)",
                "[profile] picture upload: a server failed (http)",
            ],
        );
        let refusing_url = refusing.url();
        let port = refusing_url.rsplit(':').next().expect("a port").to_string();
        for line in &lines {
            for needle in [
                sha_hex.as_str(),
                &sha_hex[..8],
                pubkey_hex.as_str(),
                &pubkey_hex[..8],
                npub.as_str(),
                refusing_url.as_str(),
                dead_url.as_str(),
                "127.0.0.1",
                port.as_str(),
                "blossom-reason",
                "blocked",
            ] {
                assert!(
                    !line.contains(needle),
                    "a log line named `{needle}`: {line}"
                );
            }
        }
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

    #[test]
    fn redirect_refusal_table() {
        let sha = "e".repeat(64);
        let refusal =
            |next: &str, hop: usize| redirect_refusal(&url::Url::parse(next).unwrap(), hop);
        // A target need not carry the requested address: the final body's hash
        // against the requested URL is the integrity check.
        assert_eq!(refusal(&format!("https://cdn.example/{sha}.jpg"), 1), None);
        assert_eq!(
            refusal("https://cdn.example/cache/key-addressed.jpg", 1),
            None
        );
        assert_eq!(refusal("https://8.8.8.8/x", 1), None);
        assert_eq!(
            refusal("https://cdn.example/x", BLOSSOM_MAX_REDIRECTS),
            None
        );
        assert_eq!(
            refusal("https://cdn.example/x", BLOSSOM_MAX_REDIRECTS + 1),
            Some(RedirectRefused::Hops)
        );
        for insecure in [
            "http://cdn.example/x",
            "ftp://cdn.example/x",
            "http://8.8.8.8/x",
        ] {
            assert_eq!(
                refusal(insecure, 1),
                Some(RedirectRefused::Scheme),
                "{insecure}"
            );
        }
        // The connector dials a literal without asking the resolver, so the
        // policy is the only filter a literal meets. `2130706433` is
        // 127.0.0.1 in decimal; the URL parser normalizes it to a literal.
        for private in [
            "https://10.0.0.5/x",
            "https://127.0.0.1/x",
            "https://[::1]/x",
            "https://[::ffff:192.168.0.1]/x",
            "https://[64:ff9b::a00:5]/x",
            "https://2130706433/x",
            "https://0x7f.1/x",
        ] {
            assert_eq!(
                refusal(private, 1),
                Some(RedirectRefused::Address),
                "{private}"
            );
        }
    }

    #[tokio::test]
    async fn download_does_not_dial_a_redirect_to_a_private_address_literal() {
        let bytes = tiny_jpeg();
        let sha_hex = hex::encode(Sha256::digest(&bytes));
        let mut target = mockito::Server::new_async().await;
        let never = target
            .mock("GET", mockito::Matcher::Any)
            .with_status(200)
            .with_body(bytes)
            .expect(0)
            .create_async()
            .await;
        let mut origin = mockito::Server::new_async().await;
        let _r = origin
            .mock("GET", format!("/{sha_hex}").as_str())
            .with_status(302)
            .with_header("location", &format!("{}/{sha_hex}", target.url()))
            .create_async()
            .await;
        let url = url::Url::parse(&format!("{}/{sha_hex}", origin.url())).unwrap();
        let err = download_with_client(&download_client(true).unwrap(), &url)
            .await
            .expect_err("a loopback literal is never dialled");
        assert!(matches!(err, ProfileError::InsecureUrl), "got {err:?}");
        never.assert_async().await;
    }

    #[tokio::test]
    async fn download_of_an_unaddressed_url_follows_no_redirect() {
        // Without a content address nothing binds the bytes a redirect would
        // fetch, so the 302 is a non-success status — not even judged by the
        // redirect policy, which would answer InsecureUrl for this target.
        let mut target = mockito::Server::new_async().await;
        let never = target
            .mock("GET", mockito::Matcher::Any)
            .expect(0)
            .create_async()
            .await;
        let mut origin = mockito::Server::new_async().await;
        let _r = origin
            .mock("GET", "/blob")
            .with_status(302)
            .with_header("location", &format!("{}/blob", target.url()))
            .create_async()
            .await;
        let url = url::Url::parse(&format!("{}/blob", origin.url())).unwrap();
        let err = download_with_client(&download_client(false).unwrap(), &url)
            .await
            .expect_err("redirect not followed");
        assert!(matches!(err, ProfileError::Http(_)), "got {err:?}");
        never.assert_async().await;
    }

    #[test]
    fn a_refused_redirect_renders_no_target() {
        for refused in [
            RedirectRefused::Hops,
            RedirectRefused::Scheme,
            RedirectRefused::Address,
        ] {
            let rendered = format!("{refused} {refused:?}");
            for needle in ["://", "127.0.0.1", "example"] {
                assert!(!rendered.contains(needle), "{rendered}");
            }
        }
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
        let base = url::Url::parse(&base).expect("valid base url");
        let server = UploadServer {
            site: base.host_str().expect("a host").to_string(),
            base,
            auth: BlossomAuthEncoding::PaddedStandard,
        };
        let jpeg = tiny_jpeg();

        let pic = upload_profile_picture(&keys, &[server], staged(&jpeg))
            .await
            .expect("live upload succeeds (server returns 201 for a new blob)");
        assert_eq!(pic.sha256_hex.len(), 64, "sha256 hex present");
        assert!(
            pic.url.contains(&pic.sha256_hex),
            "descriptor url is content-addressed"
        );
        let round = download_profile_picture(&pic.url)
            .await
            .expect("live download + re-validate succeeds");
        assert_eq!(round.sha256_hex, pic.sha256_hex, "round-trip sha matches");
        assert!(!round.canonical.is_empty(), "re-validated canonical bytes");
    }
}
