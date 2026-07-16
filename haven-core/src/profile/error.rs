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
    /// wrapped detail is redacted at `Debug` time.
    #[error("blossom error: {0}")]
    Blossom(String),

    /// A raw HTTP transport failure (connect/read/status). The wrapped detail
    /// is redacted at `Debug` time.
    #[error("http error: {0}")]
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
    /// wrapped detail is redacted at `Debug` time.
    #[error("event build error: {0}")]
    Build(String),

    /// A relay publish/fetch operation failed. The wrapped detail is redacted
    /// at `Debug` time.
    #[error("relay error: {0}")]
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
    /// the storage layer (never image or key content) and is redacted at
    /// `Debug` time.
    #[error("profile cache error: {0}")]
    Sqlite(String),
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

/// Hand-written redacting `Debug` (NOT derived): the rendered message is passed
/// through [`redact_hex_sequences`] so a `{:?}` of any variant — including the
/// string-carrying ones — can never surface a full-length pubkey or sha256 hex.
impl fmt::Debug for ProfileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "ProfileError({})",
            redact_hex_sequences(&self.to_string())
        )
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
    fn debug_redacts_pubkey_hex() {
        // A full 64-char pubkey hex embedded in a wrapped detail must be gone
        // from the Debug output.
        let pubkey_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert!(has_hex_run_ge16(pubkey_hex), "detector sanity");
        let err = ProfileError::Blossom(format!("upload failed for {pubkey_hex}"));
        let debug = format!("{err:?}");
        assert!(
            !has_hex_run_ge16(&debug),
            "Debug must not carry a >=16 hex run: {debug}"
        );
        assert!(
            !debug.contains(pubkey_hex),
            "literal hex must be gone: {debug}"
        );
        assert!(
            debug.contains("[REDACTED]"),
            "redaction must be marked: {debug}"
        );
    }

    #[test]
    fn constructors_redact_display_too() {
        // The `blossom`/`http`/… constructors pre-redact, so even Display is
        // safe (belt and braces alongside the redacting Debug).
        let sha = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
        let err = ProfileError::http(format!("connect to host {sha} refused"));
        assert!(!err.to_string().contains(sha));
        assert!(!has_hex_run_ge16(&err.to_string()));
    }

    #[test]
    fn image_error_is_transparent() {
        let err = ProfileError::from(AvatarError::UnsupportedFormat);
        // Transparent Display delegates to the (content-free) AvatarError.
        assert_eq!(err.to_string(), AvatarError::UnsupportedFormat.to_string());
    }
}
