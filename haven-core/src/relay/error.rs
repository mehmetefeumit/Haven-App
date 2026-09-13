//! Error types for relay operations.
//!
//! This module defines error types that can occur during relay
//! communication and event publishing.

use thiserror::Error;

use super::clock_skew::{DeviceClockComplaint, DEVICE_CLOCK_REJECTED_TOKEN};

/// Why a relay URL was refused.
///
/// A typed reason rather than a message built from the URL: the rejected URL is
/// the user's own relay list, and an error string is exactly what reaches a log
/// line and the FFI (Security Rule 15).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum InvalidUrlReason {
    /// Plaintext `ws://` outside the debug-only loopback opt-in.
    #[error("plaintext ws:// not allowed for security")]
    PlaintextWs,
    /// The URL could not be parsed as a relay URL at all.
    #[error("unparseable relay URL")]
    Unparseable,
}

/// Errors that can occur during relay operations.
#[derive(Error)]
#[non_exhaustive]
pub enum RelayError {
    /// Event publishing failed.
    ///
    /// The inner string carries the underlying nostr-sdk detail for the
    /// `?`-propagating caller and is excluded from BOTH renderings: it can quote
    /// a relay URL and the relay's own refusal text.
    #[error("Failed to publish event")]
    Publish(String),

    /// Invalid relay URL.
    #[error("Invalid relay URL: {0}")]
    InvalidUrl(InvalidUrlReason),

    /// Invalid public key.
    #[error("Invalid public key format")]
    InvalidPubkey,

    /// Subscription failed.
    ///
    /// Inner detail excluded from both renderings, as for [`Self::Publish`].
    #[error("Subscription failed")]
    Subscription(String),

    /// Timeout waiting for operation.
    ///
    /// Inner detail excluded from both renderings, as for [`Self::Publish`]: a
    /// caller describes WHICH operation timed out, and on the publish path that
    /// description counted the relays that stayed silent (Security Rule 15).
    #[error("Operation timed out")]
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
    /// Inner detail excluded from both renderings, as for [`Self::Publish`].
    #[error("Failed to fetch events")]
    Fetch(String),

    /// No events found.
    #[error("No events found for filter")]
    NoEventsFound,
}

impl RelayError {
    /// A stable, Haven-authored token naming the variant and nothing else.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Publish(_) => "publish",
            Self::InvalidUrl(InvalidUrlReason::PlaintextWs) => "invalid-url-plaintext-ws",
            Self::InvalidUrl(InvalidUrlReason::Unparseable) => "invalid-url-unparseable",
            Self::InvalidPubkey => "invalid-pubkey",
            Self::Subscription(_) => "subscription",
            Self::Timeout(_) => "timeout",
            Self::NotInitialized => "not-initialized",
            Self::AllRelaysFailed => "all-relays-failed",
            Self::DeviceClockRejected { .. } => "device-clock-rejected",
            Self::Initialization(_) => "initialization",
            Self::Fetch(_) => "fetch",
            Self::NoEventsFound => "no-events-found",
        }
    }
}

/// Prints the variant's [`code`](RelayError::code) and nothing else.
///
/// A `{:?}` of an error reaches panic messages, `expect` output and every
/// `unwrap` on a relay result, where the wrapped nostr-sdk prose — which quotes
/// relay URLs and the relay's own `OK`/`NOTICE` text — would be a leak Haven
/// cannot see coming (Security Rule 15 / Rule 8).
impl std::fmt::Debug for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RelayError({})", self.code())
    }
}

/// Result type for relay operations.
pub type RelayResult<T> = Result<T, RelayError>;

#[cfg(test)]
mod tests {
    use super::*;

    /// The needles every rendering below must be free of: a relay URL and the
    /// relay's own words (Security Rule 15 / Rule 8).
    const RELAY_URL: &str = "wss://relay.example.com";

    #[test]
    fn publish_error_display_redacts_inner_detail() {
        let error = RelayError::Publish(format!("rate limited by {RELAY_URL}"));
        // Display must NOT include the inner detail — it can carry relay URLs.
        assert_eq!(error.to_string(), "Failed to publish event");
    }

    #[test]
    fn publish_error_debug_redacts_inner_detail() {
        // `Debug` used to expose the detail "for logs". Under Security Rule 15 a
        // `{:?}` is a log line, a panic message and an `expect` string, so the
        // inner prose — which quotes the relay's URL and its refusal text — is
        // absent from both renderings and only the variant code survives.
        let error = RelayError::Publish(format!("rate limited by {RELAY_URL}"));
        crate::assert_debug_redacted!(
            error,
            "RelayError",
            &["rate limited", RELAY_URL, "relay.example.com"]
        );
        assert_eq!(format!("{error:?}"), "RelayError(publish)");
    }

    #[test]
    fn invalid_url_error_display_names_the_reason_not_the_url() {
        let error = RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs);
        assert_eq!(
            error.to_string(),
            "Invalid relay URL: plaintext ws:// not allowed for security"
        );
        crate::assert_display_redacted!(
            error,
            "RelayError",
            marker = "Invalid relay URL",
            &["ws://insecure.relay.com", "insecure.relay.com"]
        );
        assert_eq!(
            RelayError::InvalidUrl(InvalidUrlReason::Unparseable).to_string(),
            "Invalid relay URL: unparseable relay URL"
        );
    }

    #[test]
    fn subscription_error_display_redacts_inner_detail() {
        let error = RelayError::Subscription(format!("filter too broad on {RELAY_URL}"));
        assert_eq!(error.to_string(), "Subscription failed");
    }

    #[test]
    fn subscription_error_debug_redacts_inner_detail() {
        let error = RelayError::Subscription(format!("filter too broad on {RELAY_URL}"));
        crate::assert_debug_redacted!(
            error,
            "RelayError",
            &["filter too broad", RELAY_URL, "relay.example.com"]
        );
    }

    #[test]
    fn timeout_error_display() {
        let error = RelayError::Timeout(format!("3 relay(s) of {RELAY_URL} did not answer"));
        assert_eq!(error.to_string(), "Operation timed out");
        crate::assert_display_redacted!(
            error,
            "RelayError",
            marker = "Operation timed out",
            &["3 relay(s)", RELAY_URL, "relay.example.com"]
        );
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
        assert_eq!(debug_str, "RelayError(not-initialized)");
    }

    #[test]
    fn fetch_error_display_redacts_inner_detail() {
        let error = RelayError::Fetch(format!("connection reset on {RELAY_URL}"));
        assert_eq!(error.to_string(), "Failed to fetch events");
    }

    #[test]
    fn fetch_error_debug_redacts_inner_detail() {
        let error = RelayError::Fetch(format!("connection reset on {RELAY_URL}"));
        crate::assert_debug_redacted!(
            error,
            "RelayError",
            &["connection reset", RELAY_URL, "relay.example.com"]
        );
    }

    #[test]
    fn every_variant_code_is_distinct_and_is_all_debug_discloses() {
        // The code IS the `Debug` rendering, so a new variant that forgets a
        // code would otherwise silently share another's — and a reader would
        // mis-attribute the failure.
        let codes = [
            RelayError::Publish(String::new()).code(),
            RelayError::InvalidUrl(InvalidUrlReason::PlaintextWs).code(),
            RelayError::InvalidUrl(InvalidUrlReason::Unparseable).code(),
            RelayError::InvalidPubkey.code(),
            RelayError::Subscription(String::new()).code(),
            RelayError::Timeout(String::new()).code(),
            RelayError::NotInitialized.code(),
            RelayError::AllRelaysFailed.code(),
            RelayError::DeviceClockRejected {
                complaint: DeviceClockComplaint::Ahead,
            }
            .code(),
            RelayError::Initialization(String::new()).code(),
            RelayError::Fetch(String::new()).code(),
            RelayError::NoEventsFound.code(),
        ];
        let unique: std::collections::HashSet<&str> = codes.iter().copied().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "codes must be distinct: {codes:?}"
        );
    }

    #[test]
    fn no_events_found_error_display() {
        let error = RelayError::NoEventsFound;
        assert_eq!(error.to_string(), "No events found for filter");
    }
}
