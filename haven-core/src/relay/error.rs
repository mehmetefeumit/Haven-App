//! Error types for relay operations.
//!
//! This module defines error types that can occur during relay
//! communication and event publishing.

use thiserror::Error;

use super::clock_skew::{DeviceClockComplaint, DEVICE_CLOCK_REJECTED_TOKEN};

/// Errors that can occur during relay operations.
#[derive(Debug, Error)]
#[non_exhaustive]
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
    ///
    /// The inner string carries the underlying nostr-sdk detail for Debug/logs
    /// but is intentionally excluded from `Display` to avoid leaking relay URLs
    /// or internal diagnostic data to the UI layer.
    #[error("Failed to publish event")]
    Publish(String),

    /// Invalid relay URL.
    #[error("Invalid relay URL: {0}")]
    InvalidUrl(String),

    /// Invalid public key.
    #[error("Invalid public key format")]
    InvalidPubkey,

    /// Subscription failed.
    ///
    /// Inner detail kept for logs but excluded from `Display`.
    #[error("Subscription failed")]
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

    /// No relay accepted the event, and at least one blamed this device's
    /// clock.
    ///
    /// Split out of [`Self::AllRelaysFailed`] because the two need completely
    /// different handling: a generic publish failure is worth retrying and
    /// worth reporting as "sharing is not working", whereas this one is
    /// permanent until the user fixes their clock and is worth reporting as
    /// exactly that. Before this variant existed the distinction was
    /// unrecoverable above the relay layer — `publish_with_retry` collapsed
    /// every unsuccessful outcome to `AllRelaysFailed` and dropped the
    /// per-relay reasons on the floor, so the reason never crossed the FFI at
    /// all.
    ///
    /// # Display is a machine token, on purpose
    ///
    /// The FFI flattens errors to `String`, and this is the one classification
    /// that has to survive that flattening. `Display` therefore renders a
    /// stable, Haven-authored token — `haven.clock.device_clock_rejected:ahead`
    /// — and **never** the relay's own words. Relay prose is consumed by
    /// [`super::clock_skew::classify_relay_rejection`] and discarded there, so
    /// no remote-controlled text can reach a log or a UI string (Security
    /// Rule 8). The token is matched in Dart by
    /// `haven/lib/src/services/clock_skew_detector.dart`, and the pair is
    /// pinned by `scripts/ci/check_clock_skew_policy_parity.sh`.
    #[error("{DEVICE_CLOCK_REJECTED_TOKEN}:{}", complaint.wire_token())]
    DeviceClockRejected {
        /// What the relays said about the direction of the skew.
        complaint: DeviceClockComplaint,
    },

    /// Initialization failed.
    #[error("Initialization failed: {0}")]
    Initialization(String),

    /// Event fetch failed.
    ///
    /// Inner detail kept for logs but excluded from `Display`.
    #[error("Failed to fetch events")]
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
    fn publish_error_display_redacts_inner_detail() {
        let error = RelayError::Publish("rate limited by wss://relay.example.com".to_string());
        // Display must NOT include the inner detail — it can carry relay URLs.
        assert_eq!(error.to_string(), "Failed to publish event");
        // Debug still exposes detail for logs.
        assert!(format!("{error:?}").contains("rate limited"));
    }

    #[test]
    fn invalid_url_error_display() {
        let error = RelayError::InvalidUrl("ws://insecure".to_string());
        assert_eq!(error.to_string(), "Invalid relay URL: ws://insecure");
    }

    #[test]
    fn subscription_error_display_redacts_inner_detail() {
        let error =
            RelayError::Subscription("filter too broad on wss://relay.example.com".to_string());
        assert_eq!(error.to_string(), "Subscription failed");
        assert!(format!("{error:?}").contains("filter too broad"));
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
    fn device_clock_rejected_display_is_a_stable_machine_token() {
        // This exact rendering is the ONLY thing that survives the FFI's
        // `Result<T, String>` flattening, and Dart matches it verbatim. If it
        // changes, `clock_skew_detector.dart` stops recognising a fast-clock
        // rejection and the failure goes silent again — which is the entire
        // defect this variant exists to fix.
        assert_eq!(
            RelayError::DeviceClockRejected {
                complaint: DeviceClockComplaint::Ahead,
            }
            .to_string(),
            "haven.clock.device_clock_rejected:ahead"
        );
        assert_eq!(
            RelayError::DeviceClockRejected {
                complaint: DeviceClockComplaint::Behind,
            }
            .to_string(),
            "haven.clock.device_clock_rejected:behind"
        );
        assert_eq!(
            RelayError::DeviceClockRejected {
                complaint: DeviceClockComplaint::Unspecified,
            }
            .to_string(),
            "haven.clock.device_clock_rejected:unspecified"
        );
    }

    #[test]
    fn device_clock_rejected_display_carries_no_relay_text() {
        // Security Rule 8 / no-relay-prose invariant: the variant has nowhere
        // to put remote text, and Display must stay free of it even as the
        // enum grows.
        let rendered = RelayError::DeviceClockRejected {
            complaint: DeviceClockComplaint::Unspecified,
        }
        .to_string();
        assert!(rendered.starts_with(DEVICE_CLOCK_REJECTED_TOKEN));
        assert!(!rendered.contains("wss://"));
        assert!(!rendered.contains("invalid:"));
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
    fn invalid_pubkey_error_display() {
        let error = RelayError::InvalidPubkey;
        assert_eq!(error.to_string(), "Invalid public key format");
    }

    #[test]
    fn error_debug_format() {
        let error = RelayError::NotInitialized;
        let debug_str = format!("{error:?}");
        assert!(debug_str.contains("NotInitialized"));
    }

    #[test]
    fn fetch_error_display_redacts_inner_detail() {
        let error = RelayError::Fetch("connection reset on wss://relay.example.com".to_string());
        assert_eq!(error.to_string(), "Failed to fetch events");
        assert!(format!("{error:?}").contains("connection reset"));
    }

    #[test]
    fn no_events_found_error_display() {
        let error = RelayError::NoEventsFound;
        assert_eq!(error.to_string(), "No events found for filter");
    }
}
