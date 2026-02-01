//! Error types for Nostr operations.

use thiserror::Error;

/// Errors that can occur during Nostr event construction and encryption.
#[derive(Error, Debug)]
pub enum NostrError {
    /// MLS group operation failed.
    #[error("MLS group operation failed: {0}")]
    MlsGroup(String),

    /// Encryption operation failed.
    #[error("Encryption failed: {0}")]
    Encryption(String),

    /// Decryption operation failed.
    #[error("Decryption failed: {0}")]
    Decryption(String),

    /// Key derivation failed.
    #[error("Key derivation failed: {0}")]
    KeyDerivation(String),

    /// Event signing failed.
    #[error("Event signing failed: {0}")]
    Signing(String),

    /// Serialization failed.
    #[error("Serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),

    /// Invalid event structure or content.
    #[error("Invalid event: {0}")]
    InvalidEvent(String),

    /// Exporter secret is not available (wrong epoch or not in group).
    #[error("Exporter secret unavailable for epoch {0}")]
    ExporterSecretUnavailable(u64),

    /// Event has expired (NIP-40).
    #[error("Event has expired")]
    Expired,

    /// Event signature verification failed.
    #[error("Invalid event signature")]
    InvalidSignature,

    /// Hex encoding/decoding error.
    #[error("Hex encoding error: {0}")]
    HexError(String),

    /// MDK operation failed.
    #[error("MDK error: {0}")]
    MdkError(String),

    /// Group not found.
    #[error("Group not found: {0}")]
    GroupNotFound(String),

    /// Invalid welcome message.
    #[error("Invalid welcome message: {0}")]
    InvalidWelcome(String),

    /// Storage operation failed.
    #[error("Storage error: {0}")]
    StorageError(String),
}

/// Result type for Nostr operations.
pub type Result<T> = std::result::Result<T, NostrError>;

impl From<hex::FromHexError> for NostrError {
    fn from(e: hex::FromHexError) -> Self {
        Self::HexError(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_mls_group() {
        let err = NostrError::MlsGroup("test error".to_string());
        assert_eq!(err.to_string(), "MLS group operation failed: test error");
    }

    #[test]
    fn error_display_encryption() {
        let err = NostrError::Encryption("cipher failed".to_string());
        assert_eq!(err.to_string(), "Encryption failed: cipher failed");
    }

    #[test]
    fn error_display_decryption() {
        let err = NostrError::Decryption("invalid mac".to_string());
        assert_eq!(err.to_string(), "Decryption failed: invalid mac");
    }

    #[test]
    fn error_display_exporter_secret() {
        let err = NostrError::ExporterSecretUnavailable(42);
        assert_eq!(err.to_string(), "Exporter secret unavailable for epoch 42");
    }

    #[test]
    fn error_display_expired() {
        let err = NostrError::Expired;
        assert_eq!(err.to_string(), "Event has expired");
    }

    #[test]
    fn error_from_serde_json() {
        let json_err = serde_json::from_str::<i32>("invalid").unwrap_err();
        let err: NostrError = json_err.into();
        assert!(matches!(err, NostrError::Serialization(_)));
    }

    #[test]
    fn error_from_hex() {
        let hex_err = hex::decode("not valid hex").unwrap_err();
        let err: NostrError = hex_err.into();
        assert!(matches!(err, NostrError::HexError(_)));
    }

    #[test]
    fn error_display_key_derivation() {
        let err = NostrError::KeyDerivation("invalid key".to_string());
        assert_eq!(err.to_string(), "Key derivation failed: invalid key");
    }

    #[test]
    fn error_display_signing() {
        let err = NostrError::Signing("signer unavailable".to_string());
        assert_eq!(err.to_string(), "Event signing failed: signer unavailable");
    }

    #[test]
    fn error_display_invalid_event() {
        let err = NostrError::InvalidEvent("missing field".to_string());
        assert_eq!(err.to_string(), "Invalid event: missing field");
    }

    #[test]
    fn error_display_invalid_signature() {
        let err = NostrError::InvalidSignature;
        assert_eq!(err.to_string(), "Invalid event signature");
    }

    #[test]
    fn error_display_hex_error() {
        let err = NostrError::HexError("bad hex".to_string());
        assert_eq!(err.to_string(), "Hex encoding error: bad hex");
    }
}
