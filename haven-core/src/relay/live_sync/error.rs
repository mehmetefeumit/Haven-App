//! Errors for the live-sync engine, with redaction-safe `Display`.
//!
//! Every message that could carry MLS group identifiers or relay/MDK internals
//! is passed through [`crate::nostr::mls::redact_hex_sequences`] at construction
//! time, so a `Display`/`to_string()` of any [`LiveSyncError`] never leaks a
//! group id or secret material (Security Rule 6 / 8).

use crate::nostr::mls::redact_hex_sequences;

/// An error from the live-sync engine.
#[derive(Debug, thiserror::Error)]
pub enum LiveSyncError {
    /// A session operation was attempted with no active session.
    #[error("no active live-sync session")]
    NoSession,

    /// A relay/pool operation failed. The detail is pre-redacted.
    #[error("relay error: {0}")]
    Relay(String),

    /// An MLS/decrypt operation failed. The detail is pre-redacted.
    #[error("mls error: {0}")]
    Mls(String),

    /// A competitor commit JSON could not be parsed back into an event.
    ///
    /// Surfaced as a hard error to the finalize site so a malformed competitor
    /// is never silently dropped (a silent drop would degrade convergence to
    /// the eager-merge fork leg).
    #[error("invalid competitor commit")]
    InvalidCompetitor,

    /// A bounded operation exceeded its deadline.
    #[error("operation timed out")]
    Timeout,
}

impl LiveSyncError {
    /// Builds a [`LiveSyncError::Relay`] from any displayable source, redacting
    /// hex sequences first.
    pub fn relay<E: std::fmt::Display>(e: E) -> Self {
        Self::Relay(redact_hex_sequences(&e.to_string()))
    }

    /// Builds a [`LiveSyncError::Mls`] from any displayable source, redacting
    /// hex sequences first.
    pub fn mls<E: std::fmt::Display>(e: E) -> Self {
        Self::Mls(redact_hex_sequences(&e.to_string()))
    }
}

/// Convenience result alias for live-sync operations.
pub type LiveSyncResult<T> = std::result::Result<T, LiveSyncError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_constructor_redacts_hex_sequences() {
        // A 32-hex-char run (a plausible group-id fragment) must be redacted in
        // the rendered message.
        let raw = "boom deadbeefdeadbeefdeadbeefdeadbeef tail";
        let err = LiveSyncError::relay(raw);
        let shown = err.to_string();
        assert!(
            !shown.contains("deadbeefdeadbeefdeadbeefdeadbeef"),
            "long hex run must be redacted: {shown}"
        );
        assert!(shown.starts_with("relay error:"));
    }

    #[test]
    fn mls_constructor_redacts_hex_sequences() {
        let err = LiveSyncError::mls("fail aabbccddeeff00112233445566778899 here");
        let shown = err.to_string();
        assert!(!shown.contains("aabbccddeeff00112233445566778899"));
        assert!(shown.starts_with("mls error:"));
    }

    #[test]
    fn unit_variants_render_without_detail() {
        assert_eq!(
            LiveSyncError::NoSession.to_string(),
            "no active live-sync session"
        );
        assert_eq!(
            LiveSyncError::InvalidCompetitor.to_string(),
            "invalid competitor commit"
        );
        assert_eq!(LiveSyncError::Timeout.to_string(), "operation timed out");
    }
}
