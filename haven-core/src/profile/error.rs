//! Error types for the public-profile (kind-0 + Blossom) module.
//!
//! Profile errors carry **hex** identifiers (pubkeys, sha256 digests) rather
//! than bech32 (`npub…`) values, so the standard [`redact_hex_sequences`]
//! floor applies: the hand-written [`Debug`] impl passes the rendered message
//! through it, guaranteeing that a logged or FFI-surfaced error can never leak
//! a full-length pubkey or content hash (Security Rule 6 / 8).
//!
//! The variant set intentionally covers the whole module — including the
//! network-facing operations (Blossom upload/download, relay fetch/publish)
//! implemented in a later wave — so downstream code has a stable error surface
//! to build on.

use std::fmt;

use thiserror::Error;

use crate::avatar::AvatarError;
use crate::util::redact_hex_sequences;

/// Result alias for public-profile operations.
pub type Result<T> = std::result::Result<T, ProfileError>;

/// Errors that can occur across the public-profile module.
///
/// `Display` renders a short, user-presentable message; the manual [`Debug`]
/// impl (not derived) redacts any 16+ character hex run so neither a log line
/// nor an FFI error string can leak a pubkey or content hash.
#[derive(Error)]
pub enum ProfileError {
    /// A Blossom (BUD-02/BUD-11) protocol or upload operation failed. The
    /// wrapped detail — SERVER-authored text — is kept for programmatic use and
    /// rendered by neither `Display` nor `Debug` (Security Rule 15).
    #[error("blossom error")]
    Blossom(String),

    /// A raw HTTP transport failure (connect/read/status). The wrapped detail
    /// carries the host, so neither rendering prints it.
    #[error("http error")]
    Http(String),

    /// A bounded network operation exceeded its deadline.
    #[error("operation timed out")]
    Timeout,

    /// A downloaded blob's sha256 did not match the content-addressed URL hash
    /// (Blossom integrity commitment broken). Data-free: no hashes echoed.
    #[error("content hash mismatch")]
    HashMismatch,

    /// A URL was rejected for being non-HTTPS, or for resolving to a
    /// loopback / private / link-local / ULA / multicast address (anti-SSRF).
    /// Data-free: the rejected URL is never echoed.
    #[error("insecure or disallowed url")]
    InsecureUrl,

    /// A payload exceeded the configured size cap (Content-Length precheck or
    /// streamed overrun). Data-free: the actual size is never echoed.
    #[error("payload too large")]
    TooLarge,

    /// Building a Nostr event (kind-0 metadata or kind-24242 auth) failed. The
    /// wrapped detail is never rendered.
    #[error("event build error")]
    Build(String),

    /// A relay publish/fetch operation failed. The wrapped detail carries the
    /// relay's URL and its own `NOTICE`/`OK` prose, so it is never rendered.
    #[error("relay error")]
    Relay(String),

    /// The effective relay set was empty (fail-closed — Haven never falls back
    /// to broadcasting profile traffic to an unintended relay).
    #[error("no relays available")]
    NoRelays,

    /// A URL could not be parsed / was structurally invalid. Data-free.
    #[error("invalid url")]
    BadUrl,

    /// The avatar image pipeline (decode / sanitize / re-encode) failed. Its
    /// own `Display` is already content-free.
    #[error(transparent)]
    Image(#[from] AvatarError),

    /// A local `SQLite` / cache operation failed. The wrapped detail comes from
    /// the storage layer, which can echo a bound parameter, so it is never
    /// rendered.
    #[error("profile cache error")]
    Sqlite(String),

    /// Structurally invalid non-URL input (currently: a malformed persisted
    /// relay-assignment salt). The rejected value is never echoed.
    #[error("invalid profile data")]
    InvalidData(String),

    /// Too few profile-plane relays survived contamination exclusion.
    ///
    /// Fail-closed and TERMINAL: the profile plane must never fall back to the
    /// discovery plane or to a relay carrying the user's location traffic,
    /// because that fallback would silently re-create the exact cross-plane
    /// join the pool exists to prevent. Carries counts only — never URLs — so
    /// it stays safe to surface across the FFI.
    #[error("profile relay pool exhausted")]
    PoolUnderflow {
        /// Relays left after excluding every contaminated entry.
        usable: usize,
        /// Minimum required to operate the profile plane.
        required: usize,
    },
}

impl ProfileError {
    /// Builds a [`ProfileError::Blossom`] from any displayable source, redacting
    /// hex runs so even the `Display` string is safe.
    #[must_use]
    pub fn blossom<E: fmt::Display>(source: E) -> Self {
        Self::Blossom(redact_hex_sequences(&source.to_string()))
    }

    /// Builds a [`ProfileError::Http`] from any displayable source, redacting
    /// hex runs so even the `Display` string is safe.
    #[must_use]
    pub fn http<E: fmt::Display>(source: E) -> Self {
        Self::Http(redact_hex_sequences(&source.to_string()))
    }

    /// Builds a [`ProfileError::Build`] from any displayable source, redacting
    /// hex runs so even the `Display` string is safe.
    #[must_use]
    pub fn build<E: fmt::Display>(source: E) -> Self {
        Self::Build(redact_hex_sequences(&source.to_string()))
    }

    /// Builds a [`ProfileError::Relay`] from any displayable source, redacting
    /// hex runs so even the `Display` string is safe.
    #[must_use]
    pub fn relay<E: fmt::Display>(source: E) -> Self {
        Self::Relay(redact_hex_sequences(&source.to_string()))
    }

    /// Builds a [`ProfileError::Sqlite`] from any displayable source, redacting
    /// hex runs so even the `Display` string is safe.
    #[must_use]
    pub fn sqlite<E: fmt::Display>(source: E) -> Self {
        Self::Sqlite(redact_hex_sequences(&source.to_string()))
    }
}

impl ProfileError {
    /// A stable, value-free token naming the variant, for log lines.
    ///
    /// `Blossom`, `Http` and `Relay` carry text a SERVER wrote; a relay or a
    /// Blossom host can therefore choose what a Haven log line says, which is
    /// why a log line says only this (Security Rule 15, Rule 8).
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Blossom(_) => "blossom",
            Self::Http(_) => "http",
            Self::Timeout => "timeout",
            Self::HashMismatch => "hash-mismatch",
            Self::InsecureUrl => "insecure-url",
            Self::TooLarge => "too-large",
            Self::Build(_) => "build",
            Self::Relay(_) => "relay",
            Self::NoRelays => "no-relays",
            Self::BadUrl => "bad-url",
            Self::Image(_) => "image",
            Self::Sqlite(_) => "sqlite",
            Self::InvalidData(_) => "invalid-data",
            Self::PoolUnderflow { .. } => "pool-underflow",
        }
    }
}

/// Hand-written `Debug` (NOT derived): it prints the variant's
/// [`code`](ProfileError::code) only. The string-carrying variants wrap
/// server-authored text, which no `{:?}` — in a log, a panic or an `expect` —
/// may republish (Security Rule 15).
impl fmt::Debug for ProfileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ProfileError({})", self.code())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Independent detector for a contiguous hex run >= 16 chars. Written from
    /// scratch (NOT via the redactor) so it cannot mask a regression.
    fn has_hex_run_ge16(s: &str) -> bool {
        let mut run = 0usize;
        for b in s.bytes() {
            if b.is_ascii_hexdigit() {
                run += 1;
                if run >= 16 {
                    return true;
                }
            } else {
                run = 0;
            }
        }
        false
    }

    #[test]
    fn profile_error_debug_redacts_the_wrapped_prose() {
        // A full 64-char pubkey hex embedded in a wrapped detail must be gone
        // from the Debug output — and so must the server's own prose around it.
        let pubkey_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert!(has_hex_run_ge16(pubkey_hex), "detector sanity");
        let err = ProfileError::Blossom(format!("upload failed for {pubkey_hex}"));
        crate::assert_debug_redacted!(&err, "ProfileError", &[pubkey_hex, "upload failed for"]);
        let debug = format!("{err:?}");
        assert!(
            !has_hex_run_ge16(&debug),
            "Debug must not carry a >=16 hex run: {debug}"
        );
        assert_eq!(debug, "ProfileError(blossom)");
    }

    #[test]
    fn error_codes_are_distinct_and_value_free() {
        let codes = [
            ProfileError::Blossom(String::new()).code(),
            ProfileError::Http(String::new()).code(),
            ProfileError::Timeout.code(),
            ProfileError::HashMismatch.code(),
            ProfileError::InsecureUrl.code(),
            ProfileError::TooLarge.code(),
            ProfileError::Build(String::new()).code(),
            ProfileError::Relay(String::new()).code(),
            ProfileError::NoRelays.code(),
            ProfileError::BadUrl.code(),
            ProfileError::Image(AvatarError::UnsupportedFormat).code(),
            ProfileError::Sqlite(String::new()).code(),
            ProfileError::InvalidData(String::new()).code(),
            ProfileError::PoolUnderflow {
                usable: 0,
                required: 2,
            }
            .code(),
        ];
        let unique: std::collections::BTreeSet<&str> = codes.iter().copied().collect();
        assert_eq!(unique.len(), codes.len(), "a code is reused: {codes:?}");
        for code in codes {
            assert!(
                code.chars().all(|c| c.is_ascii_lowercase() || c == '-'),
                "a code must be a fixed token, not a value: {code}"
            );
        }
    }

    #[test]
    fn profile_error_display_redacts_the_wrapped_prose() {
        // `Display` crosses the FFI into Dart, whose default error handler
        // prints an exception's message verbatim, so the server-authored detail
        // (and the host inside it) must be absent from it — the constructors'
        // `redact_hex_sequences` pre-pass stays as defence in depth, not as the
        // mechanism (Security Rule 15).
        let sha = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
        let cases = [
            (
                ProfileError::http(format!("connect to blossom.example {sha} refused")),
                "http error",
            ),
            (
                ProfileError::blossom(format!("507 insufficient storage for {sha}")),
                "blossom error",
            ),
            (
                ProfileError::relay("wss://relay.example.com: rate-limited".to_string()),
                "relay error",
            ),
            (
                ProfileError::Sqlite(format!("UNIQUE failed: profiles.{sha}")),
                "profile cache error",
            ),
        ];
        for (err, expected) in cases {
            crate::assert_display_redacted!(
                &err,
                "ProfileError",
                marker = expected,
                &[
                    sha,
                    "blossom.example",
                    "wss://relay.example.com",
                    "rate-limited"
                ]
            );
            let display = err.to_string();
            assert_eq!(display, expected);
            assert!(!display.contains(&sha[..8]), "{display}");
            assert!(!has_hex_run_ge16(&display));
        }
    }

    #[test]
    fn image_error_is_transparent() {
        let err = ProfileError::from(AvatarError::UnsupportedFormat);
        // Transparent Display delegates to the (content-free) AvatarError.
        assert_eq!(err.to_string(), AvatarError::UnsupportedFormat.to_string());
    }
}
