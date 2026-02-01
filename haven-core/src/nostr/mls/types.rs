//! Shared types for MDK integration.
//!
//! This module re-exports and aliases types from the MDK crate
//! for use throughout the haven-core library.

// Re-export core MDK types
pub use mdk_core::prelude::{
    GroupId, GroupResult, JoinedGroupResult, MessageProcessingResult, NostrGroupConfigData,
    NostrGroupDataUpdate, UpdateGroupResult, WelcomePreview,
};

// Re-export storage types
pub use mdk_core::prelude::group_types::Group as MlsGroup;
pub use mdk_core::prelude::group_types::GroupExporterSecret;
pub use mdk_core::prelude::message_types::Message as MlsMessage;
pub use mdk_core::prelude::welcome_types::Welcome as MlsWelcome;

/// Configuration for creating a location sharing group.
///
/// This is a simplified configuration focused on location sharing use cases.
/// It wraps `NostrGroupConfigData` with sensible defaults.
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
    /// # Arguments
    ///
    /// * `name` - The name of the group (e.g., "Smith Family")
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
/// This provides a simplified view of the group state
/// suitable for the location sharing use case.
#[derive(Debug, Clone)]
pub struct LocationGroupInfo {
    /// The MLS group ID (used for MDK operations)
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

impl LocationGroupInfo {
    /// Creates group info from an MDK Group.
    ///
    /// This function is used internally to convert MDK group data
    /// to the Haven-specific `LocationGroupInfo` representation.
    #[allow(dead_code)] // Reserved for future MDK integration
    pub(crate) fn from_mls_group(group: &MlsGroup, epoch: u64) -> Self {
        Self {
            mls_group_id: group.mls_group_id.clone(),
            // Convert [u8; 32] to hex string
            nostr_group_id: hex::encode(group.nostr_group_id),
            name: group.name.clone(),
            description: group.description.clone(),
            epoch,
        }
    }
}

/// Result of processing an incoming location message.
#[derive(Debug)]
pub enum LocationMessageResult {
    /// A decrypted location message
    Location {
        /// The sender's public key (hex-encoded)
        sender_pubkey: String,
        /// The decrypted content (JSON)
        content: String,
        /// The MLS group ID this message belongs to
        group_id: GroupId,
    },
    /// A group update (member added/removed, etc.)
    GroupUpdate {
        /// The MLS group ID that was updated
        group_id: GroupId,
    },
    /// Message could not be processed
    Unprocessable {
        /// The MLS group ID
        group_id: GroupId,
        /// Error description
        reason: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn location_group_info_debug_output() {
        let group_id = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        let info = LocationGroupInfo {
            mls_group_id: group_id,
            nostr_group_id: "abc123".to_string(),
            name: "Test Group".to_string(),
            description: "A test group".to_string(),
            epoch: 42,
        };

        let debug_str = format!("{:?}", info);
        assert!(debug_str.contains("LocationGroupInfo"));
        assert!(debug_str.contains("abc123"));
        assert!(debug_str.contains("Test Group"));
        assert!(debug_str.contains("42"));
    }

    #[test]
    fn location_group_info_clone() {
        let group_id = GroupId::from_slice(&[1, 2, 3]);
        let info1 = LocationGroupInfo {
            mls_group_id: group_id.clone(),
            nostr_group_id: "test".to_string(),
            name: "Name".to_string(),
            description: "Desc".to_string(),
            epoch: 5,
        };

        let info2 = info1.clone();

        assert_eq!(info1.nostr_group_id, info2.nostr_group_id);
        assert_eq!(info1.name, info2.name);
        assert_eq!(info1.description, info2.description);
        assert_eq!(info1.epoch, info2.epoch);
    }

    #[test]
    fn location_group_config_default_values() {
        let config = LocationGroupConfig::new("Group");

        assert_eq!(config.name, "Group");
        assert!(config.description.is_empty());
        assert!(config.relays.is_empty());
        assert!(config.admins.is_empty());
    }

    #[test]
    fn location_group_config_chained_with_relays() {
        let config = LocationGroupConfig::new("Test")
            .with_relay("wss://r1.com")
            .with_relays(["wss://r2.com", "wss://r3.com"])
            .with_relay("wss://r4.com");

        assert_eq!(config.relays.len(), 4);
        assert_eq!(config.relays[0], "wss://r1.com");
        assert_eq!(config.relays[3], "wss://r4.com");
    }

    #[test]
    fn location_message_result_location_variant() {
        let group_id = GroupId::from_slice(&[1, 2, 3]);
        let result = LocationMessageResult::Location {
            sender_pubkey: "pubkey123".to_string(),
            content: r#"{"lat":0}"#.to_string(),
            group_id,
        };

        // Verify it can be pattern matched
        if let LocationMessageResult::Location {
            sender_pubkey,
            content,
            ..
        } = result
        {
            assert_eq!(sender_pubkey, "pubkey123");
            assert!(content.contains("lat"));
        } else {
            panic!("Expected Location variant");
        }
    }

    #[test]
    fn location_message_result_group_update_variant() {
        let group_id = GroupId::from_slice(&[4, 5, 6]);
        let result = LocationMessageResult::GroupUpdate { group_id };

        if let LocationMessageResult::GroupUpdate { group_id: gid } = result {
            assert_eq!(gid.as_slice(), &[4, 5, 6]);
        } else {
            panic!("Expected GroupUpdate variant");
        }
    }

    #[test]
    fn location_message_result_unprocessable_variant() {
        let group_id = GroupId::from_slice(&[7, 8, 9]);
        let result = LocationMessageResult::Unprocessable {
            group_id,
            reason: "Test error".to_string(),
        };

        if let LocationMessageResult::Unprocessable { reason, .. } = result {
            assert_eq!(reason, "Test error");
        } else {
            panic!("Expected Unprocessable variant");
        }
    }
}
