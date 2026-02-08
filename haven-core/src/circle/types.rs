//! Core types for circle management.
//!
//! This module defines the data structures for circles (groups of people
//! who share locations), contacts (locally-stored member profiles), and
//! related types.
//!
//! # Privacy Model
//!
//! Haven uses a privacy-first approach where user profiles are stored
//! locally on each device, never published to Nostr relays. This prevents
//! relay-level correlation of usernames with invitation patterns.

use crate::nostr::mls::types::GroupId;

/// Default relay URLs for demo/development.
///
/// These are well-maintained public relays that support the required NIPs
/// (NIP-01, NIP-40, NIP-44, NIP-59) for Marmot Protocol operation.
pub const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.nostr.wine",
    "wss://nos.lol",
];

/// Type of circle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CircleType {
    /// Multi-member location sharing circle (e.g., family).
    #[default]
    LocationSharing,
    /// Direct 1:1 location sharing.
    DirectShare,
}

impl CircleType {
    /// Converts to string representation for storage.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::LocationSharing => "location_sharing",
            Self::DirectShare => "direct_share",
        }
    }

    /// Parses from string representation.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "location_sharing" => Some(Self::LocationSharing),
            "direct_share" => Some(Self::DirectShare),
            _ => None,
        }
    }
}

/// Membership status in a circle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MembershipStatus {
    /// Invitation received, not yet responded.
    Pending,
    /// User accepted and joined the circle.
    Accepted,
    /// User declined the invitation.
    Declined,
}

impl MembershipStatus {
    /// Converts to string representation for storage.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Accepted => "accepted",
            Self::Declined => "declined",
        }
    }

    /// Parses from string representation.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(Self::Pending),
            "accepted" => Some(Self::Accepted),
            "declined" => Some(Self::Declined),
            _ => None,
        }
    }

    /// Returns whether the circle should be visible in the UI.
    #[must_use]
    pub const fn is_visible(&self) -> bool {
        matches!(self, Self::Pending | Self::Accepted)
    }
}

/// A circle (group of people who share locations).
///
/// This is the application-level representation of a group, containing
/// metadata stored locally on the device.
#[derive(Clone)]
pub struct Circle {
    /// MLS group ID (links to MDK storage).
    pub mls_group_id: GroupId,
    /// Nostr group ID (32 bytes, used in h-tags for routing).
    pub nostr_group_id: [u8; 32],
    /// User-facing display name (local only).
    pub display_name: String,
    /// Type of circle.
    pub circle_type: CircleType,
    /// Relay URLs for publishing and receiving group messages.
    pub relays: Vec<String>,
    /// When the circle was created (Unix timestamp).
    pub created_at: i64,
    /// When the circle was last updated (Unix timestamp).
    pub updated_at: i64,
}

impl std::fmt::Debug for Circle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Circle")
            .field("mls_group_id", &"<redacted>")
            .field("nostr_group_id", &hex::encode(self.nostr_group_id))
            .field("display_name", &self.display_name)
            .field("circle_type", &self.circle_type)
            .field("relays", &self.relays)
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .finish()
    }
}

/// Membership state in a circle.
///
/// Tracks the user's relationship with a circle, including invitation
/// state and who invited them.
#[derive(Clone)]
pub struct CircleMembership {
    /// MLS group ID this membership belongs to.
    pub mls_group_id: GroupId,
    /// Current membership status.
    pub status: MembershipStatus,
    /// Public key (hex) of who invited us, if known.
    pub inviter_pubkey: Option<String>,
    /// When we were invited (Unix timestamp).
    pub invited_at: i64,
    /// When we responded to the invitation (Unix timestamp).
    pub responded_at: Option<i64>,
}

impl std::fmt::Debug for CircleMembership {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleMembership")
            .field("mls_group_id", &"<redacted>")
            .field("status", &self.status)
            .field("inviter_pubkey", &self.inviter_pubkey)
            .field("invited_at", &self.invited_at)
            .field("responded_at", &self.responded_at)
            .finish()
    }
}

/// Local contact information.
///
/// **Privacy Note**: This is stored only on the user's device, never
/// synced to Nostr relays. Each user assigns their own display names
/// and avatars to contacts, similar to phone contacts.
#[derive(Debug, Clone)]
pub struct Contact {
    /// Nostr public key (hex) - the ONLY identifier visible on relays.
    pub pubkey: String,
    /// Locally assigned display name.
    pub display_name: Option<String>,
    /// Local file path to avatar image.
    pub avatar_path: Option<String>,
    /// Optional notes about this contact.
    pub notes: Option<String>,
    /// When this contact was created (Unix timestamp).
    pub created_at: i64,
    /// When this contact was last updated (Unix timestamp).
    pub updated_at: i64,
}

/// A circle member with resolved local contact info.
///
/// When displaying circle members, this type combines the member's
/// pubkey with any locally-stored contact information.
#[derive(Debug, Clone)]
pub struct CircleMember {
    /// Nostr public key (hex) - always available.
    pub pubkey: String,
    /// Display name from local Contact, if set.
    pub display_name: Option<String>,
    /// Avatar path from local Contact, if set.
    pub avatar_path: Option<String>,
    /// Whether this member is a group admin.
    pub is_admin: bool,
}

/// UI state for a circle.
#[derive(Clone)]
pub struct CircleUiState {
    /// MLS group ID.
    pub mls_group_id: GroupId,
    /// ID of last read message.
    pub last_read_message_id: Option<String>,
    /// Pin order (lower = higher priority).
    pub pin_order: Option<i32>,
    /// Whether notifications are muted.
    pub is_muted: bool,
}

impl std::fmt::Debug for CircleUiState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleUiState")
            .field("mls_group_id", &"<redacted>")
            .field("last_read_message_id", &self.last_read_message_id)
            .field("pin_order", &self.pin_order)
            .field("is_muted", &self.is_muted)
            .finish()
    }
}

/// Configuration for creating a new circle.
#[derive(Debug, Clone)]
pub struct CircleConfig {
    /// Circle name.
    pub name: String,
    /// Optional description.
    pub description: Option<String>,
    /// Type of circle.
    pub circle_type: CircleType,
    /// Relay URLs for the circle.
    pub relays: Vec<String>,
}

impl CircleConfig {
    /// Creates a new circle configuration.
    #[must_use]
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: None,
            circle_type: CircleType::default(),
            relays: Vec::new(),
        }
    }

    /// Sets the description.
    #[must_use]
    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        self.description = Some(description.into());
        self
    }

    /// Sets the circle type.
    #[must_use]
    pub const fn with_type(mut self, circle_type: CircleType) -> Self {
        self.circle_type = circle_type;
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
}

/// Circle with its membership and member list.
#[derive(Debug, Clone)]
pub struct CircleWithMembers {
    /// The circle.
    pub circle: Circle,
    /// User's membership in this circle.
    pub membership: CircleMembership,
    /// Members with resolved contact info.
    pub members: Vec<CircleMember>,
}

/// Pending invitation to join a circle.
#[derive(Clone)]
pub struct Invitation {
    /// MLS group ID.
    pub mls_group_id: GroupId,
    /// Circle name.
    pub circle_name: String,
    /// Public key (hex) of who invited us.
    pub inviter_pubkey: String,
    /// Number of members in the circle.
    pub member_count: usize,
    /// When we were invited (Unix timestamp).
    pub invited_at: i64,
}

impl std::fmt::Debug for Invitation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Invitation")
            .field("mls_group_id", &"<redacted>")
            .field("circle_name", &self.circle_name)
            .field("inviter_pubkey", &self.inviter_pubkey)
            .field("member_count", &self.member_count)
            .field("invited_at", &self.invited_at)
            .finish()
    }
}

/// A member's key package with their inbox relay list.
///
/// Used when adding members to a circle. The inbox relays are fetched
/// from the member's kind 10051 relay list and used for publishing
/// the gift-wrapped Welcome.
#[derive(Debug, Clone)]
pub struct MemberKeyPackage {
    /// The key package event (kind 443).
    pub key_package_event: nostr::Event,
    /// Relay URLs where the Welcome should be sent (from kind 10051).
    pub inbox_relays: Vec<String>,
}

/// A gift-wrapped Welcome ready for publishing.
///
/// Contains the kind 1059 gift-wrapped event along with recipient
/// information needed for relay publishing.
#[derive(Debug, Clone)]
pub struct GiftWrappedWelcome {
    /// The recipient's Nostr public key (hex).
    pub recipient_pubkey: String,
    /// Relay URLs to publish this Welcome to (recipient's inbox relays).
    pub recipient_relays: Vec<String>,
    /// The gift-wrapped event (kind 1059), ready to publish.
    pub event: nostr::Event,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circle_type_default() {
        assert_eq!(CircleType::default(), CircleType::LocationSharing);
    }

    #[test]
    fn circle_type_as_str() {
        assert_eq!(CircleType::LocationSharing.as_str(), "location_sharing");
        assert_eq!(CircleType::DirectShare.as_str(), "direct_share");
    }

    #[test]
    fn circle_type_parse() {
        assert_eq!(
            CircleType::parse("location_sharing"),
            Some(CircleType::LocationSharing)
        );
        assert_eq!(
            CircleType::parse("direct_share"),
            Some(CircleType::DirectShare)
        );
        assert_eq!(CircleType::parse("invalid"), None);
    }

    #[test]
    fn membership_status_as_str() {
        assert_eq!(MembershipStatus::Pending.as_str(), "pending");
        assert_eq!(MembershipStatus::Accepted.as_str(), "accepted");
        assert_eq!(MembershipStatus::Declined.as_str(), "declined");
    }

    #[test]
    fn membership_status_parse() {
        assert_eq!(
            MembershipStatus::parse("pending"),
            Some(MembershipStatus::Pending)
        );
        assert_eq!(
            MembershipStatus::parse("accepted"),
            Some(MembershipStatus::Accepted)
        );
        assert_eq!(
            MembershipStatus::parse("declined"),
            Some(MembershipStatus::Declined)
        );
        assert_eq!(MembershipStatus::parse("invalid"), None);
    }

    #[test]
    fn membership_status_is_visible() {
        assert!(MembershipStatus::Pending.is_visible());
        assert!(MembershipStatus::Accepted.is_visible());
        assert!(!MembershipStatus::Declined.is_visible());
    }

    #[test]
    fn circle_config_builder() {
        let config = CircleConfig::new("Test Circle")
            .with_description("A test circle")
            .with_type(CircleType::DirectShare)
            .with_relay("wss://relay1.example.com")
            .with_relays(["wss://relay2.example.com", "wss://relay3.example.com"]);

        assert_eq!(config.name, "Test Circle");
        assert_eq!(config.description, Some("A test circle".to_string()));
        assert_eq!(config.circle_type, CircleType::DirectShare);
        assert_eq!(config.relays.len(), 3);
    }

    #[test]
    fn contact_clone() {
        let contact = Contact {
            pubkey: "abc123".to_string(),
            display_name: Some("Alice".to_string()),
            avatar_path: Some("/path/to/avatar.jpg".to_string()),
            notes: Some("Test notes".to_string()),
            created_at: 1000,
            updated_at: 2000,
        };

        let contact2 = contact.clone();
        assert_eq!(contact.pubkey, contact2.pubkey);
        assert_eq!(contact.display_name, contact2.display_name);
        assert_eq!(contact.avatar_path, contact2.avatar_path);
        assert_eq!(contact.notes, contact2.notes);
    }

    #[test]
    fn circle_member_debug() {
        let member = CircleMember {
            pubkey: "abc123".to_string(),
            display_name: Some("Bob".to_string()),
            avatar_path: None,
            is_admin: true,
        };

        let debug_str = format!("{:?}", member);
        assert!(debug_str.contains("CircleMember"));
        assert!(debug_str.contains("Bob"));
        assert!(debug_str.contains("is_admin: true"));
    }

    #[test]
    fn circle_debug_redacts_mls_group_id() {
        let circle = Circle {
            mls_group_id: GroupId::from_slice(&[0xAB, 0xCD, 0xEF, 0x01, 0x23]),
            nostr_group_id: [0x42; 32],
            display_name: "Test Circle".to_string(),
            circle_type: CircleType::LocationSharing,
            relays: vec!["wss://relay.example.com".to_string()],
            created_at: 1000,
            updated_at: 2000,
        };

        let debug_str = format!("{circle:?}");
        assert!(
            debug_str.contains("<redacted>"),
            "MLS group ID should be redacted"
        );
        assert!(debug_str.contains("Test Circle"));
        // nostr_group_id should appear as hex
        assert!(debug_str.contains("42424242"));
        // Raw bytes should NOT appear
        assert!(!debug_str.contains("abcdef0123"));
    }

    #[test]
    fn circle_membership_debug_redacts_mls_group_id() {
        let membership = CircleMembership {
            mls_group_id: GroupId::from_slice(&[0xDE, 0xAD]),
            status: MembershipStatus::Pending,
            inviter_pubkey: Some("inviter123".to_string()),
            invited_at: 5000,
            responded_at: None,
        };

        let debug_str = format!("{membership:?}");
        assert!(debug_str.contains("<redacted>"));
        assert!(debug_str.contains("Pending"));
        assert!(debug_str.contains("inviter123"));
    }

    #[test]
    fn circle_ui_state_debug_redacts_mls_group_id() {
        let state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[0xFF; 16]),
            last_read_message_id: Some("msg-123".to_string()),
            pin_order: Some(1),
            is_muted: false,
        };

        let debug_str = format!("{state:?}");
        assert!(debug_str.contains("<redacted>"));
        assert!(debug_str.contains("msg-123"));
        assert!(debug_str.contains("pin_order: Some(1)"));
        assert!(debug_str.contains("is_muted: false"));
    }

    #[test]
    fn invitation_debug_redacts_mls_group_id() {
        let invitation = Invitation {
            mls_group_id: GroupId::from_slice(&[0x11; 8]),
            circle_name: "Family Circle".to_string(),
            inviter_pubkey: "pubkey456".to_string(),
            member_count: 5,
            invited_at: 9000,
        };

        let debug_str = format!("{invitation:?}");
        assert!(debug_str.contains("<redacted>"));
        assert!(debug_str.contains("Family Circle"));
        assert!(debug_str.contains("pubkey456"));
        assert!(debug_str.contains("member_count: 5"));
    }

    #[test]
    fn circle_clone() {
        let circle = Circle {
            mls_group_id: GroupId::from_slice(&[1, 2, 3]),
            nostr_group_id: [0x99; 32],
            display_name: "Clone Test".to_string(),
            circle_type: CircleType::DirectShare,
            relays: vec!["wss://r1.com".to_string()],
            created_at: 100,
            updated_at: 200,
        };

        let cloned = circle.clone();
        assert_eq!(cloned.display_name, "Clone Test");
        assert_eq!(cloned.circle_type, CircleType::DirectShare);
        assert_eq!(cloned.nostr_group_id, [0x99; 32]);
    }

    #[test]
    fn circle_membership_clone() {
        let membership = CircleMembership {
            mls_group_id: GroupId::from_slice(&[1]),
            status: MembershipStatus::Accepted,
            inviter_pubkey: Some("abc".to_string()),
            invited_at: 100,
            responded_at: Some(200),
        };

        let cloned = membership.clone();
        assert_eq!(cloned.status, MembershipStatus::Accepted);
        assert_eq!(cloned.inviter_pubkey, Some("abc".to_string()));
        assert_eq!(cloned.responded_at, Some(200));
    }

    #[test]
    fn circle_with_members_debug() {
        let cwm = CircleWithMembers {
            circle: Circle {
                mls_group_id: GroupId::from_slice(&[1]),
                nostr_group_id: [0; 32],
                display_name: "Test".to_string(),
                circle_type: CircleType::LocationSharing,
                relays: vec![],
                created_at: 0,
                updated_at: 0,
            },
            membership: CircleMembership {
                mls_group_id: GroupId::from_slice(&[1]),
                status: MembershipStatus::Accepted,
                inviter_pubkey: None,
                invited_at: 0,
                responded_at: None,
            },
            members: vec![],
        };

        let debug_str = format!("{cwm:?}");
        assert!(debug_str.contains("CircleWithMembers"));
    }

    #[test]
    fn member_key_package_debug() {
        let keys = nostr::Keys::generate();
        let signed_event = nostr::EventBuilder::new(nostr::Kind::Custom(443), "test-content")
            .sign_with_keys(&keys)
            .unwrap();

        let mkp = MemberKeyPackage {
            key_package_event: signed_event,
            inbox_relays: vec!["wss://relay.example.com".to_string()],
        };

        let debug_str = format!("{mkp:?}");
        assert!(debug_str.contains("MemberKeyPackage"));
    }

    #[test]
    fn gift_wrapped_welcome_debug() {
        let keys = nostr::Keys::generate();
        let signed_event = nostr::EventBuilder::new(nostr::Kind::Custom(1059), "wrapped-content")
            .sign_with_keys(&keys)
            .unwrap();

        let gww = GiftWrappedWelcome {
            recipient_pubkey: "recipient-pubkey-hex".to_string(),
            recipient_relays: vec!["wss://relay.example.com".to_string()],
            event: signed_event,
        };

        let debug_str = format!("{gww:?}");
        assert!(debug_str.contains("GiftWrappedWelcome"));
        assert!(debug_str.contains("recipient-pubkey-hex"));
    }

    #[test]
    fn circle_config_new_defaults() {
        let config = CircleConfig::new("My Circle");
        assert_eq!(config.name, "My Circle");
        assert!(config.description.is_none());
        assert_eq!(config.circle_type, CircleType::LocationSharing);
        assert!(config.relays.is_empty());
    }

    #[test]
    fn default_relays_constant() {
        assert!(!DEFAULT_RELAYS.is_empty());
        for relay in DEFAULT_RELAYS {
            assert!(relay.starts_with("wss://"));
        }
    }
}
