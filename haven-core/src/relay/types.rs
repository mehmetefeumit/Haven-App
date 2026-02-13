//! Types for relay management.
//!
//! This module defines types for relay status and publish results.

use nostr::EventId;

/// Connection status for a relay.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayStatus {
    /// Not connected to the relay.
    Disconnected,

    /// Connecting to the relay.
    Connecting,

    /// Connected and ready.
    Connected,

    /// Connection failed.
    Failed {
        /// The reason for the failure.
        reason: String,
    },
}

/// Status of a single relay connection.
#[derive(Debug, Clone)]
pub struct RelayConnectionStatus {
    /// The relay URL.
    pub url: String,
    /// Current connection status.
    pub status: RelayStatus,
    /// Last time the relay was seen (Unix timestamp).
    pub last_seen: Option<i64>,
}

/// Result of publishing an event to relays.
#[derive(Debug, Clone)]
pub struct PublishResult {
    /// The event ID that was published.
    pub event_id: EventId,
    /// Relays that accepted the event.
    pub accepted_by: Vec<String>,
    /// Relays that rejected the event (with reasons).
    pub rejected_by: Vec<(String, String)>,
    /// Relays that failed to respond.
    pub failed: Vec<String>,
}

impl PublishResult {
    /// Returns true if at least one relay accepted the event.
    #[must_use]
    pub const fn is_success(&self) -> bool {
        !self.accepted_by.is_empty()
    }

    /// Returns the number of successful relays.
    #[must_use]
    pub const fn success_count(&self) -> usize {
        self.accepted_by.len()
    }

    /// Returns the total number of relays attempted.
    #[must_use]
    pub const fn total_attempted(&self) -> usize {
        self.accepted_by.len() + self.rejected_by.len() + self.failed.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_status_variants() {
        assert_eq!(RelayStatus::Disconnected, RelayStatus::Disconnected);
        assert_eq!(RelayStatus::Connecting, RelayStatus::Connecting);
        assert_eq!(RelayStatus::Connected, RelayStatus::Connected);

        let failed = RelayStatus::Failed {
            reason: "test".to_string(),
        };
        if let RelayStatus::Failed { reason } = failed {
            assert_eq!(reason, "test");
        }
    }

    #[test]
    fn publish_result_is_success_with_accepted() {
        let result = PublishResult {
            event_id: EventId::all_zeros(),
            accepted_by: vec!["wss://relay.example.com".to_string()],
            rejected_by: vec![],
            failed: vec![],
        };
        assert!(result.is_success());
        assert_eq!(result.success_count(), 1);
        assert_eq!(result.total_attempted(), 1);
    }

    #[test]
    fn publish_result_not_success_when_empty() {
        let result = PublishResult {
            event_id: EventId::all_zeros(),
            accepted_by: vec![],
            rejected_by: vec![("wss://relay.com".to_string(), "rejected".to_string())],
            failed: vec!["wss://fail.com".to_string()],
        };
        assert!(!result.is_success());
        assert_eq!(result.success_count(), 0);
        assert_eq!(result.total_attempted(), 2);
    }

    #[test]
    fn relay_connection_status_debug() {
        let status = RelayConnectionStatus {
            url: "wss://relay.example.com".to_string(),
            status: RelayStatus::Connected,
            last_seen: Some(1_234_567_890),
        };
        let debug_str = format!("{:?}", status);
        assert!(debug_str.contains("RelayConnectionStatus"));
        assert!(debug_str.contains("wss://relay.example.com"));
    }
}
