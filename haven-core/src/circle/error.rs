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
}

/// Result type alias for circle operations.
pub type Result<T> = std::result::Result<T, CircleError>;

impl From<crate::nostr::NostrError> for CircleError {
    fn from(err: crate::nostr::NostrError) -> Self {
        Self::Mls(err.to_string())
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
}
