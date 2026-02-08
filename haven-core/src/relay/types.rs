//! Types for relay management.
//!
//! This module defines types for relay status, publish results,
//! and circuit isolation purposes.

use nostr::EventId;

/// Purpose of a relay connection for circuit isolation.
///
/// Different operation types use separate Tor circuits to prevent
/// correlation attacks. This enum specifies the purpose of each
/// connection to ensure proper isolation.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum CircuitPurpose {
    /// Operations related to identity (`KeyPackage` publishing, kind 443/10051).
    ///
    /// All identity-related operations share a circuit since they're
    /// already linked by the identity's public key.
    Identity,

    /// Operations related to a specific group (location messages, kind 445).
    ///
    /// Each group gets its own circuit to prevent relay-level correlation
    /// of which groups a user participates in.
    GroupMessage {
        /// The Nostr group ID (32 bytes) for circuit isolation.
        nostr_group_id: [u8; 32],
    },
}

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

/// Status of Tor bootstrap process.
#[derive(Debug, Clone)]
pub struct TorStatus {
    /// Bootstrap progress percentage (0-100).
    pub progress: u8,
    /// Whether Tor is fully bootstrapped.
    pub is_ready: bool,
    /// Current bootstrap phase description.
    pub phase: String,
}

impl TorStatus {
    /// Creates a new `TorStatus` in the initial state.
    #[must_use]
    pub fn initializing() -> Self {
        Self {
            progress: 0,
            is_ready: false,
            phase: "Initializing".to_string(),
        }
    }

    /// Creates a new `TorStatus` in the ready state.
    #[must_use]
    pub fn ready() -> Self {
        Self {
            progress: 100,
            is_ready: true,
            phase: "Ready".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circuit_purpose_identity() {
        let purpose = CircuitPurpose::Identity;
        assert_eq!(purpose, CircuitPurpose::Identity);
    }

    #[test]
    fn circuit_purpose_group_message() {
        let group_id = [1u8; 32];
        let purpose = CircuitPurpose::GroupMessage {
            nostr_group_id: group_id,
        };

        if let CircuitPurpose::GroupMessage { nostr_group_id } = purpose {
            assert_eq!(nostr_group_id, group_id);
        } else {
            panic!("Expected GroupMessage variant");
        }
    }

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
    fn tor_status_initializing() {
        let status = TorStatus::initializing();
        assert_eq!(status.progress, 0);
        assert!(!status.is_ready);
    }

    #[test]
    fn tor_status_ready() {
        let status = TorStatus::ready();
        assert_eq!(status.progress, 100);
        assert!(status.is_ready);
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
