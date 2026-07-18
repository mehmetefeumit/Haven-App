//! Shared types for the Marmot "Dark Matter" MLS integration.
//!
//! This module re-exports the value types Haven's MLS surface needs from the
//! Dark Matter crate set (`cgka-traits` / `cgka-session`) and defines the
//! Haven-local location wrappers.
//!
//! # `GroupId` compatibility shim
//!
//! The Dark Matter [`GroupId`] (`cgka_traits::types::GroupId`) constructs from
//! bytes via `GroupId::new(bytes)` and reads via `as_slice()` / `into_bytes()`
//! — it does **not** expose the old MDK `from_slice` / `to_vec` pair. Haven has
//! many `GroupId::from_slice(&bytes)` call sites (circle storage, tests), so
//! [`GroupIdExt`] restores `from_slice` as an extension over the new type. The
//! byte contract is identical; bring [`GroupIdExt`] into scope to use it.

// ── Dark Matter re-exports (the DM-3 consumer surface) ───────────────────────
pub use cgka_session::{CreateGroupEffects, IngestEffects, PublishWork, SessionEffects};
pub use cgka_traits::app_components::AppComponentData;
pub use cgka_traits::engine::{
    CreateGroupRequest, GroupEvent, GroupStateChange, KeyPackage, KeyPackageSource, SendIntent,
    WelcomeMetadata,
};
pub use cgka_traits::engine_state::PendingStateRef;
pub use cgka_traits::group::{Group as MlsGroup, Member as MlsMember};
pub use cgka_traits::ingest::{IngestOutcome, StaleReason};
pub use cgka_traits::transport::TransportMessage;
pub use cgka_traits::types::{EpochId, GroupId, MemberId, MessageId};
pub use nostr::Event;

/// Extension trait restoring the old MDK `GroupId::from_slice` constructor over
/// the Dark Matter [`GroupId`].
///
/// The new engine names the constructor `GroupId::new`; Haven's persistence and
/// test code call `GroupId::from_slice`. This trait maps one to the other with
/// no change in the byte contract. `GroupId::as_slice()` and `into_bytes()`
/// already exist natively, so only the constructor needs a shim.
pub trait GroupIdExt {
    /// Builds a [`GroupId`] from a byte slice (alias for `GroupId::new`).
    #[must_use]
    fn from_slice(bytes: &[u8]) -> Self;
}

impl GroupIdExt for GroupId {
    fn from_slice(bytes: &[u8]) -> Self {
        Self::new(bytes.to_vec())
    }
}

/// Configuration for creating a location sharing group.
///
/// This is a simplified configuration focused on location sharing use cases.
/// The name/description become the group's `marmot.group.profile.v1` component,
/// the relays become the `marmot.transport.nostr.routing.v1` component, and the
/// admins bootstrap the group's initial admin set (the creator is always an
/// admin implicitly).
#[derive(Debug, Clone)]
pub struct LocationGroupConfig {
    /// Name of the family/group (e.g., "Smith Family")
    pub name: String,
    /// Optional description
    pub description: String,
    /// Relay URLs for the group
    pub relays: Vec<String>,
    /// Admin public keys (hex-encoded)
    pub admins: Vec<String>,
}

impl LocationGroupConfig {
    /// Creates a new location group configuration.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::mls::types::LocationGroupConfig;
    ///
    /// let config = LocationGroupConfig::new("Smith Family")
    ///     .with_description("Our family location sharing group")
    ///     .with_relay("wss://relay.example.com");
    /// ```
    #[must_use]
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: String::new(),
            relays: Vec::new(),
            admins: Vec::new(),
        }
    }

    /// Sets the group description.
    #[must_use]
    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        self.description = description.into();
        self
    }

    /// Adds a relay URL.
    #[must_use]
    pub fn with_relay(mut self, relay: impl Into<String>) -> Self {
        self.relays.push(relay.into());
        self
    }

    /// Adds multiple relay URLs.
    #[must_use]
    pub fn with_relays(mut self, relays: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.relays.extend(relays.into_iter().map(Into::into));
        self
    }

    /// Adds an admin public key (hex-encoded).
    #[must_use]
    pub fn with_admin(mut self, admin_pubkey: impl Into<String>) -> Self {
        self.admins.push(admin_pubkey.into());
        self
    }
}

/// Information about a joined or created group.
///
/// A simplified, redaction-safe view of the group state suitable for the
/// location sharing use case. The `nostr_group_id` here is the transport
/// routing id (from the `marmot.transport.nostr.routing.v1` component), never
/// the real MLS `GroupId`.
#[derive(Clone)]
pub struct LocationGroupInfo {
    /// The MLS group ID (used for engine operations)
    pub mls_group_id: GroupId,
    /// The Nostr group ID (used in h-tags for relay routing)
    pub nostr_group_id: String,
    /// Group name
    pub name: String,
    /// Group description
    pub description: String,
    /// Current epoch number (for forward secrecy tracking)
    pub epoch: u64,
}

impl std::fmt::Debug for LocationGroupInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocationGroupInfo")
            .field("mls_group_id", &"<redacted>")
            .field("nostr_group_id", &self.nostr_group_id)
            .field("name", &self.name)
            .field("description", &self.description)
            .field("epoch", &self.epoch)
            .finish()
    }
}

/// Result of interpreting an ordered engine [`GroupEvent`] for the location
/// sharing use case.
///
/// The Dark Matter engine emits a rich `GroupEvent` stream from `ingest` /
/// `advance_convergence`; Haven folds the location-relevant subset into this
/// enum. Unlike the old `MessageProcessingResult`-derived taxonomy, stale /
/// duplicate / out-of-order handling is entirely engine-internal (surfaced as
/// [`IngestOutcome::Stale`] / [`IngestOutcome::Buffered`] on the ingest call),
/// so this type carries only application-visible outcomes.
pub enum LocationMessageResult {
    /// A decrypted inner application message (a location update).
    Location {
        /// The sender's public key (hex-encoded, from the MLS-authenticated
        /// member id).
        sender_pubkey: String,
        /// The decrypted inner content (the location JSON payload).
        content: String,
        /// The MLS group ID this message belongs to.
        group_id: GroupId,
        /// The MLS epoch the message was authenticated at.
        epoch: u64,
    },
    /// The local client joined a group via an accepted welcome.
    Joined {
        /// The MLS group ID that was joined.
        group_id: GroupId,
    },
    /// A durable, MLS-authenticated change to group state (membership, admin,
    /// rename, retention) or an epoch advance the receiver should react to.
    GroupUpdate {
        /// The MLS group ID that was updated.
        group_id: GroupId,
    },
    /// A previously-surfaced application message or state change was withdrawn
    /// because branch selection superseded the commit that produced it. The
    /// caller must treat the earlier change as if it never happened.
    Invalidated {
        /// The MLS group ID whose prior output was withdrawn.
        group_id: GroupId,
    },
    /// The group entered the unrecoverable state; the UI must block send/mutate.
    Unrecoverable {
        /// The MLS group ID that is now unrecoverable.
        group_id: GroupId,
    },
}

impl std::fmt::Debug for LocationMessageResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Location { epoch, .. } => f
                .debug_struct("Location")
                .field("sender_pubkey", &"<redacted>")
                .field("content", &"<redacted>")
                .field("group_id", &"<redacted>")
                .field("epoch", epoch)
                .finish(),
            Self::Joined { .. } => f
                .debug_struct("Joined")
                .field("group_id", &"<redacted>")
                .finish(),
            Self::GroupUpdate { .. } => f
                .debug_struct("GroupUpdate")
                .field("group_id", &"<redacted>")
                .finish(),
            Self::Invalidated { .. } => f
                .debug_struct("Invalidated")
                .field("group_id", &"<redacted>")
                .finish(),
            Self::Unrecoverable { .. } => f
                .debug_struct("Unrecoverable")
                .field("group_id", &"<redacted>")
                .finish(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_id_ext_from_slice_matches_new() {
        let a = GroupId::from_slice(&[1, 2, 3, 4]);
        let b = GroupId::new(vec![1, 2, 3, 4]);
        assert_eq!(a, b);
        assert_eq!(a.as_slice(), &[1, 2, 3, 4]);
    }

    #[test]
    fn location_group_config_builder_pattern() {
        let config = LocationGroupConfig::new("Test Family")
            .with_description("Test description")
            .with_relay("wss://relay1.example.com")
            .with_relay("wss://relay2.example.com")
            .with_admin("abc123");

        assert_eq!(config.name, "Test Family");
        assert_eq!(config.description, "Test description");
        assert_eq!(config.relays.len(), 2);
        assert_eq!(config.admins.len(), 1);
    }

    #[test]
    fn location_group_config_with_relays() {
        let relays = vec!["wss://r1.com", "wss://r2.com"];
        let config = LocationGroupConfig::new("Test").with_relays(relays);
        assert_eq!(config.relays.len(), 2);
    }

    #[test]
    fn location_group_info_debug_redacts_mls_group_id() {
        let info = LocationGroupInfo {
            mls_group_id: GroupId::from_slice(&[1, 2, 3, 4, 5]),
            nostr_group_id: "abc123".to_string(),
            name: "Test Group".to_string(),
            description: "A test group".to_string(),
            epoch: 42,
        };

        let debug_str = format!("{info:?}");
        assert!(debug_str.contains("LocationGroupInfo"));
        assert!(debug_str.contains("abc123"));
        assert!(debug_str.contains("Test Group"));
        assert!(debug_str.contains("42"));
        assert!(debug_str.contains("<redacted>"));
        assert!(
            !debug_str.contains("0102030405"),
            "MLS group ID bytes must not appear in Debug output"
        );
    }

    #[test]
    fn location_message_result_debug_redacts_group_id() {
        let result = LocationMessageResult::Location {
            sender_pubkey: "pk".to_string(),
            content: r#"{"lat":0}"#.to_string(),
            group_id: GroupId::from_slice(&[9, 9, 9]),
            epoch: 7,
        };
        let debug_str = format!("{result:?}");
        assert!(debug_str.contains("Location"));
        assert!(debug_str.contains("<redacted>"));
        assert!(debug_str.contains("epoch: 7"));
        assert!(!debug_str.contains("090909"));
        assert!(!debug_str.contains("lat"));
    }

    #[test]
    fn location_message_result_group_update_and_invalidated_redact() {
        for result in [
            LocationMessageResult::GroupUpdate {
                group_id: GroupId::from_slice(&[1]),
            },
            LocationMessageResult::Invalidated {
                group_id: GroupId::from_slice(&[2]),
            },
            LocationMessageResult::Joined {
                group_id: GroupId::from_slice(&[3]),
            },
            LocationMessageResult::Unrecoverable {
                group_id: GroupId::from_slice(&[4]),
            },
        ] {
            let debug_str = format!("{result:?}");
            assert!(debug_str.contains("<redacted>"));
        }
    }
}
