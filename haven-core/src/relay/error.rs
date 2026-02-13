//! Error types for relay operations.
//!
//! This module defines error types that can occur during relay
//! communication and event publishing.

use thiserror::Error;

/// Errors that can occur during relay operations.
#[derive(Debug, Error)]
pub enum RelayError {
    /// Connection to relay failed.
    #[error("Failed to connect to relay {url}: {reason}")]
    Connection {
        /// The relay URL that failed.
        url: String,
        /// The reason for the failure.
        reason: String,
    },

    /// Event publishing failed.
    #[error("Failed to publish event: {0}")]
    Publish(String),

    /// Invalid relay URL.
    #[error("Invalid relay URL: {0}")]
    InvalidUrl(String),

    /// Subscription failed.
    #[error("Subscription failed: {0}")]
    Subscription(String),

    /// Relay rejected the event.
    #[error("Relay {relay} rejected event: {reason}")]
    Rejected {
        /// The relay that rejected the event.
        relay: String,
        /// The rejection reason.
        reason: String,
    },

    /// Timeout waiting for operation.
    #[error("Operation timed out: {0}")]
    Timeout(String),

    /// Client not initialized.
    #[error("Relay client not initialized")]
    NotInitialized,

    /// All relays failed.
    #[error("All relays failed to accept the event")]
    AllRelaysFailed,

    /// Initialization failed.
    #[error("Initialization failed: {0}")]
    Initialization(String),

    /// Event fetch failed.
    #[error("Failed to fetch events: {0}")]
    Fetch(String),

    /// No events found.
    #[error("No events found for filter")]
    NoEventsFound,
}

/// Result type for relay operations.
pub type RelayResult<T> = Result<T, RelayError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connection_error_display() {
        let error = RelayError::Connection {
            url: "wss://relay.example.com".to_string(),
            reason: "connection refused".to_string(),
        };
        assert_eq!(
            error.to_string(),
            "Failed to connect to relay wss://relay.example.com: connection refused"
        );
    }

    #[test]
    fn publish_error_display() {
        let error = RelayError::Publish("rate limited".to_string());
        assert_eq!(error.to_string(), "Failed to publish event: rate limited");
    }

    #[test]
    fn invalid_url_error_display() {
        let error = RelayError::InvalidUrl("ws://insecure".to_string());
        assert_eq!(error.to_string(), "Invalid relay URL: ws://insecure");
    }

    #[test]
    fn subscription_error_display() {
        let error = RelayError::Subscription("filter too broad".to_string());
        assert_eq!(error.to_string(), "Subscription failed: filter too broad");
    }

    #[test]
    fn rejected_error_display() {
        let error = RelayError::Rejected {
            relay: "wss://relay.example.com".to_string(),
            reason: "blocked".to_string(),
        };
        assert_eq!(
            error.to_string(),
            "Relay wss://relay.example.com rejected event: blocked"
        );
    }

    #[test]
    fn timeout_error_display() {
        let error = RelayError::Timeout("event publish".to_string());
        assert_eq!(error.to_string(), "Operation timed out: event publish");
    }

    #[test]
    fn not_initialized_error_display() {
        let error = RelayError::NotInitialized;
        assert_eq!(error.to_string(), "Relay client not initialized");
    }

    #[test]
    fn all_relays_failed_error_display() {
        let error = RelayError::AllRelaysFailed;
        assert_eq!(error.to_string(), "All relays failed to accept the event");
    }

    #[test]
    fn initialization_error_display() {
        let error = RelayError::Initialization("failed to create directory".to_string());
        assert_eq!(
            error.to_string(),
            "Initialization failed: failed to create directory"
        );
    }

    #[test]
    fn error_debug_format() {
        let error = RelayError::NotInitialized;
        let debug_str = format!("{error:?}");
        assert!(debug_str.contains("NotInitialized"));
    }

    #[test]
    fn fetch_error_display() {
        let error = RelayError::Fetch("connection reset".to_string());
        assert_eq!(
            error.to_string(),
            "Failed to fetch events: connection reset"
        );
    }

    #[test]
    fn no_events_found_error_display() {
        let error = RelayError::NoEventsFound;
        assert_eq!(error.to_string(), "No events found for filter");
    }
}
