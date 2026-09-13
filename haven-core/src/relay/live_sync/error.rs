//! Errors for the live-sync engine, with redaction-safe renderings.
//!
//! Neither `Display` nor `Debug` discloses a payload (Security Rule 15): a
//! relay/pool or MLS message quotes relay URLs, `npub`s and short id prefixes,
//! none of which [`crate::nostr::mls::redact_hex_sequences`] removes — it only
//! collapses hex runs of 16 or more. The redaction stays at construction time as
//! defence in depth for the payload a debugger or a variant match still sees.

use crate::nostr::mls::redact_hex_sequences;

/// An error from the live-sync engine.
#[derive(thiserror::Error)]
pub enum LiveSyncError {
    /// A session operation was attempted with no active session.
    #[error("no active live-sync session")]
    NoSession,

    /// A relay/pool operation failed. The detail is pre-redacted and unrendered.
    #[error("relay error")]
    Relay(String),

    /// An MLS/decrypt operation failed. The detail is pre-redacted and
    /// unrendered.
    #[error("mls error")]
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

impl LiveSyncError {
    /// A stable, Haven-authored token naming the variant and nothing else.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::NoSession => "no-session",
            Self::Relay(_) => "relay",
            Self::Mls(_) => "mls",
            Self::InvalidCompetitor => "invalid-competitor",
            Self::Timeout => "timeout",
        }
    }
}

/// Prints the variant's [`code`](LiveSyncError::code) and nothing else — a
/// `{:?}` reaches panic and `expect` output, where the derived one printed the
/// pre-redacted detail verbatim.
impl std::fmt::Debug for LiveSyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LiveSyncError({})", self.code())
    }
}

/// Convenience result alias for live-sync operations.
pub type LiveSyncResult<T> = std::result::Result<T, LiveSyncError>;

#[cfg(test)]
mod tests {
    use super::*;

    /// A relay URL, an `npub`, a circle name and a group-id PREFIX: the four
    /// shapes `redact_hex_sequences` leaves intact, which is why neither
    /// rendering may carry a payload at all (Security Rule 15).
    const SURVIVES_THE_REDACTOR: &str = "wss://secret-relay.example.com refused for \
         npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9 \
         in Needle Circle Zephyr (group c0ffeec0)";

    #[test]
    fn relay_and_mls_display_redacts_the_whole_detail() {
        for (err, sentence) in [
            (LiveSyncError::relay(SURVIVES_THE_REDACTOR), "relay error"),
            (LiveSyncError::mls(SURVIVES_THE_REDACTOR), "mls error"),
        ] {
            assert_eq!(err.to_string(), sentence);
            crate::assert_display_redacted!(
                err,
                "LiveSyncError",
                marker = sentence,
                &[
                    "wss://secret-relay.example.com",
                    "secret-relay.example.com",
                    "npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9",
                    "Needle Circle Zephyr",
                    "c0ffeec0",
                ]
            );
        }
    }

    #[test]
    fn relay_and_mls_debug_redacts_the_whole_detail() {
        for (err, code) in [
            (LiveSyncError::relay(SURVIVES_THE_REDACTOR), "relay"),
            (LiveSyncError::mls(SURVIVES_THE_REDACTOR), "mls"),
        ] {
            assert_eq!(format!("{err:?}"), format!("LiveSyncError({code})"));
            crate::assert_debug_redacted!(
                err,
                "LiveSyncError",
                marker = code,
                &[
                    "wss://secret-relay.example.com",
                    "npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9",
                    "Needle Circle Zephyr",
                    "c0ffeec0",
                ]
            );
        }
    }

    /// The construction-time redaction stays: it is what bounds the payload a
    /// variant match or a debugger still sees, now that nothing renders it.
    #[test]
    fn the_constructors_still_redact_long_hex_runs() {
        let LiveSyncError::Relay(detail) =
            LiveSyncError::relay("boom deadbeefdeadbeefdeadbeefdeadbeef tail")
        else {
            panic!("relay() must build the Relay variant");
        };
        assert!(!detail.contains("deadbeefdeadbeefdeadbeefdeadbeef"));

        let LiveSyncError::Mls(detail) =
            LiveSyncError::mls("fail aabbccddeeff00112233445566778899 here")
        else {
            panic!("mls() must build the Mls variant");
        };
        assert!(!detail.contains("aabbccddeeff00112233445566778899"));
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
