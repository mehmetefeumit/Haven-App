//! Error types for circle management operations.
//!
//! This module defines errors that can occur during circle operations,
//! including storage errors, validation errors, and MDK errors.

use thiserror::Error;

/// Error type for circle operations.
#[derive(Error, Debug)]
pub enum CircleError {
    /// Storage operation failed.
    #[error("Storage error: {0}")]
    Storage(String),

    /// Database error from `SQLite`.
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    /// Circle not found.
    #[error("Circle not found: {0}")]
    NotFound(String),

    /// Contact not found.
    #[error("Contact not found: {0}")]
    ContactNotFound(String),

    /// Invalid data provided.
    #[error("Invalid data: {0}")]
    InvalidData(String),

    /// MDK operation failed.
    #[error("MLS error: {0}")]
    Mls(String),

    /// Circle already exists.
    #[error("Circle already exists: {0}")]
    AlreadyExists(String),

    /// Membership state conflict.
    #[error("Membership conflict: {0}")]
    MembershipConflict(String),

    /// Orphaned circle was removed from local storage.
    ///
    /// The MLS group did not exist in MDK (e.g., from a failed finalization
    /// or database reset), but local storage was cleaned up successfully.
    /// Callers should treat this as a successful leave with no evolution
    /// event to publish.
    #[error("Orphaned circle removed")]
    OrphanedCircleRemoved,

    /// Caller is the sole remaining member — no one to hand off admin
    /// rights to, so the circle is abandoned locally without a relay commit.
    ///
    /// Surfaced from [`CircleManager::plan_leave`] so the Flutter layer can
    /// decide between calling `abandon_circle_local_only` (simple cleanup)
    /// or prompting the user. The variant is intentionally data-free so that
    /// `Debug`/`Display` cannot leak the MLS group ID.
    ///
    /// [`CircleManager::plan_leave`]: crate::circle::CircleManager::plan_leave
    #[error("Last member abandon")]
    LastMemberAbandon,

    /// Gift-wrapped invitation has already been processed.
    ///
    /// Returned from `process_invitation` when the wrapper event ID is
    /// present in the `processed_gift_wraps` dedup table. This is the
    /// expected outcome when the invitation poller re-fetches a gift wrap
    /// it has already processed (NIP-59's 2-day lookback window causes
    /// every poll cycle to re-surface the same events). Callers should
    /// treat this as a silent no-op rather than surfacing it as a failure.
    ///
    /// The variant is intentionally data-free so that `Debug`/`Display`
    /// output cannot leak an MLS group ID. Use
    /// [`CircleStorage::is_gift_wrap_processed`] if you need the group ID
    /// that the wrapper was originally bound to.
    ///
    /// [`CircleStorage::is_gift_wrap_processed`]: crate::circle::storage::CircleStorage::is_gift_wrap_processed
    #[error("Invitation already processed")]
    AlreadyProcessed,
}

/// Result type alias for circle operations.
pub type Result<T> = std::result::Result<T, CircleError>;

impl From<crate::nostr::NostrError> for CircleError {
    fn from(err: crate::nostr::NostrError) -> Self {
        Self::Mls(crate::nostr::mls::redact_hex_sequences(&err.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn storage_error_display() {
        let err = CircleError::Storage("test error".to_string());
        assert_eq!(err.to_string(), "Storage error: test error");
    }

    #[test]
    fn not_found_error_display() {
        let err = CircleError::NotFound("group123".to_string());
        assert_eq!(err.to_string(), "Circle not found: group123");
    }

    #[test]
    fn contact_not_found_error_display() {
        let err = CircleError::ContactNotFound("pubkey123".to_string());
        assert_eq!(err.to_string(), "Contact not found: pubkey123");
    }

    #[test]
    fn invalid_data_error_display() {
        let err = CircleError::InvalidData("missing name".to_string());
        assert_eq!(err.to_string(), "Invalid data: missing name");
    }

    #[test]
    fn mls_error_display() {
        let err = CircleError::Mls("group creation failed".to_string());
        assert_eq!(err.to_string(), "MLS error: group creation failed");
    }

    #[test]
    fn already_exists_error_display() {
        let err = CircleError::AlreadyExists("group123".to_string());
        assert_eq!(err.to_string(), "Circle already exists: group123");
    }

    #[test]
    fn membership_conflict_error_display() {
        let err = CircleError::MembershipConflict("already accepted".to_string());
        assert_eq!(err.to_string(), "Membership conflict: already accepted");
    }

    #[test]
    fn orphaned_circle_removed_error_display() {
        let err = CircleError::OrphanedCircleRemoved;
        assert_eq!(err.to_string(), "Orphaned circle removed");
    }

    #[test]
    fn last_member_abandon_display_is_opaque() {
        let err = CircleError::LastMemberAbandon;
        assert_eq!(err.to_string(), "Last member abandon");
    }

    #[test]
    fn already_processed_error_display_is_opaque() {
        let err = CircleError::AlreadyProcessed;
        // The Display output intentionally reveals no MLS group ID, wrapper
        // event ID, or other correlatable state. Callers that need that
        // context must look it up via `CircleStorage::is_gift_wrap_processed`.
        assert_eq!(err.to_string(), "Invitation already processed");
    }

    #[test]
    fn nostr_error_conversion_redacts_long_hex_from_surfaced_message() {
        use crate::nostr::mls::redact_hex_sequences;
        use crate::nostr::NostrError;

        // Independent detector for a contiguous hex run >= 16 chars (the shape
        // of an MLS group id / key material the redactor must strip). Written
        // from scratch — NOT via the redactor — so it cannot mask a regression.
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

        // 64-char hex standing in for a leaked MLS group id / key material.
        let secret_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert!(
            has_hex_run_ge16(secret_hex),
            "detector sanity: the planted secret is a >=16 hex run"
        );
        assert!(
            !has_hex_run_ge16(&redact_hex_sequences(secret_hex)),
            "redactor sanity: a long hex run is stripped"
        );

        // `From<NostrError> for CircleError` is the boundary the FFI/UI surfaces
        // (every CircleManager op returns `Result<_, CircleError>`, which the
        // FFI renders to a String shown to developers/users). It MUST redact
        // every variant's Display so a raw MDK/group error can never reach the
        // surface carrying key material (Security Rule #6/#8).
        let cases = [
            NostrError::MdkError(format!("decryption failed for group {secret_hex}")),
            NostrError::GroupNotFound(secret_hex.to_string()),
        ];
        for nostr_err in cases {
            // Positive control: the NostrError's OWN Display leaks the hex, so
            // the absence below is attributable to the conversion, not to a
            // missing needle.
            let raw = nostr_err.to_string();
            assert!(
                has_hex_run_ge16(&raw),
                "control: NostrError Display should carry the long hex pre-conversion: {raw}"
            );

            let surfaced = CircleError::from(nostr_err).to_string();
            assert!(
                !has_hex_run_ge16(&surfaced),
                "CircleError surfaced a >=16 hex run (key/group-id leak): {surfaced}"
            );
            assert!(
                surfaced.contains("[REDACTED]"),
                "CircleError must mark the redaction: {surfaced}"
            );
            // Stronger than the run-length check alone: the literal needle must
            // be gone, catching a redactor bug that split the run into sub-16
            // chunks (which `has_hex_run_ge16` would miss).
            assert!(
                !surfaced.contains(secret_hex),
                "the literal secret hex must not survive redaction: {surfaced}"
            );
        }
    }
}
