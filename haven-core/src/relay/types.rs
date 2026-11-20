//! Types for relay management.
//!
//! This module defines types for relay status and publish results.

use nostr::{Event, EventId};

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

/// Outcome of a per-relay event fetch.
///
/// Distinguishes a relay that answered our connection (`responded == true`,
/// even when it returned zero events) from one we could not reach
/// (`responded == false`). The WebSocket handshake is the definitive
/// "reachable" signal: a relay that completes the handshake within the
/// connection timeout is counted as responded, regardless of how many
/// events it then returns. This lets a caller report an accurate
/// reached/unreached tally instead of a single merged result that hides
/// which relays were contacted.
///
/// `responded` is a transport-level signal (reachable), not proof the relay
/// answered the specific query: because connections are pooled across calls,
/// a relay reachable on a prior call may report `responded` even if its
/// socket has since gone half-open. This is the accepted, documented
/// trade-off for a simple, truthful "reachable" count. Whether the relay
/// answered THIS query is a different fact, and it has its own field —
/// [`drained`](Self::drained).
#[derive(Debug, Clone)]
pub struct RelayFetchOutcome {
    /// The relay URL that was queried.
    pub relay_url: String,
    /// Whether the relay completed the WebSocket handshake (it was reachable).
    pub responded: bool,
    /// Whether this relay stated it had served everything it stores for this
    /// filter: it sent NIP-01 `EOSE` for this REQ, and every event it sent
    /// before that reached us.
    ///
    /// The ONLY evidence a page is whole. `events` alone cannot say: a
    /// delivery cut off part-way — by the fetch timeout, a dropped socket, a
    /// `CLOSED`, or our own intake cap — is byte-for-byte a complete short
    /// answer. A caller that advances a cursor over a page must gate that
    /// advance on this flag; a page without it may be a prefix of an unknown
    /// whole, and treating it as the whole silently drops the remainder.
    pub drained: bool,
    /// Whether the relay ended this REQ with a `CLOSED` refusing the read
    /// itself (`auth-required:` or `restricted:`): it serves the filter only
    /// to a NIP-42-authenticated reader. The publish client never
    /// authenticates (Security Rule 16); an own-inbox read
    /// (`RelayManager::read_own_inbox_per_relay`) does, and is `refused` only
    /// when the relay still refused it. Never `true` with `drained`; the
    /// relay's text is not kept.
    pub refused: bool,
    /// Events fetched from this relay (empty unless `responded`), each at most
    /// once and ordered NEWEST FIRST by `created_at`, ties broken by id.
    ///
    /// The order is this device's, not the relay's: a caller that resolves an
    /// ambiguity positionally would otherwise be resolving it by whatever order
    /// the relay chose to deliver in.
    pub events: Vec<Event>,
}

/// How one relay answered a read of the user's own inbox (`kind:1059`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InboxRead {
    /// It ended the read with `EOSE`: what it holds for this account, it sent.
    Served,
    /// It refused the read: after this device answered its NIP-42 challenge,
    /// or refused that answer, or asked for one and sent no challenge. An
    /// invitation stored there is not read from it.
    Refused,
    /// It was reached but did not finish its answer.
    Incomplete,
    /// It could not be reached.
    Unreached,
}

impl RelayFetchOutcome {
    /// This answer as a read of the user's own inbox.
    #[must_use]
    pub const fn inbox_read(&self) -> InboxRead {
        if self.drained {
            InboxRead::Served
        } else if self.refused {
            InboxRead::Refused
        } else if self.responded {
            InboxRead::Incomplete
        } else {
            InboxRead::Unreached
        }
    }
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
    fn only_an_eose_serves_an_inbox_read_and_only_a_gating_close_refuses_one() {
        let answer = |responded, drained, refused| RelayFetchOutcome {
            relay_url: String::new(),
            responded,
            drained,
            refused,
            events: Vec::new(),
        };
        assert_eq!(answer(true, true, false).inbox_read(), InboxRead::Served);
        assert_eq!(answer(true, false, true).inbox_read(), InboxRead::Refused);
        assert_eq!(
            answer(true, false, false).inbox_read(),
            InboxRead::Incomplete
        );
        assert_eq!(
            answer(false, false, false).inbox_read(),
            InboxRead::Unreached
        );
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
        let debug_str = format!("{status:?}");
        assert!(debug_str.contains("RelayConnectionStatus"));
        assert!(debug_str.contains("wss://relay.example.com"));
    }
}
