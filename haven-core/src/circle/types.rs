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

use std::sync::OnceLock;

use crate::nostr::mls::types::GroupId;

/// Production default relay URLs used as a last-resort fallback in cascading
/// relay resolution.
///
/// These are well-maintained public relays that support the required NIPs
/// (NIP-01, NIP-40, NIP-44, NIP-59) for Marmot Protocol operation.
///
/// This is the source of truth for the hard-coded fallback. Runtime callers
/// should use [`default_relays`], which honors any debug-only test override
/// installed via [`set_default_relays_for_test`].
pub const PRODUCTION_DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nos.lol",
];

/// Process-static override of the default relay list. Set once via
/// [`set_default_relays_for_test`] in debug builds, never observable in
/// release.
static DEFAULT_RELAYS_OVERRIDE: OnceLock<Vec<String>> = OnceLock::new();

/// Returns the default relay list for the current process.
///
/// In production this is always a fresh `Vec<String>` materialized from
/// [`PRODUCTION_DEFAULT_RELAYS`]. In debug builds, if
/// [`set_default_relays_for_test`] has been called, the override list is
/// returned instead. The function always returns at least one entry — an
/// empty override is rejected at install time.
#[must_use]
pub fn default_relays() -> Vec<String> {
    if let Some(over) = DEFAULT_RELAYS_OVERRIDE.get() {
        return over.clone();
    }
    PRODUCTION_DEFAULT_RELAYS
        .iter()
        .map(|s| (*s).to_string())
        .collect()
}

/// Override the default relay list for E2E tests.
///
/// Intended exclusively for hermetic test harnesses that need every Rust
/// call site that touches the hard-coded relay list to redirect to a local
/// strfry on `ws://10.0.2.2:7777` (Android emulator host loopback) or
/// equivalent.
///
/// # Errors
///
/// * Returns `Err` if called more than once in the same process — the
///   override is install-once via [`OnceLock`].
/// * Returns `Err` when `relays` is empty (a zero-length override would
///   break every cascade).
///
/// In release builds the override mechanism is unreachable; the sibling
/// stub returns an error so callers fail loudly.
#[cfg(debug_assertions)]
pub fn set_default_relays_for_test(relays: Vec<String>) -> Result<(), String> {
    if relays.is_empty() {
        return Err("set_default_relays_for_test requires a non-empty list".to_string());
    }
    DEFAULT_RELAYS_OVERRIDE
        .set(relays)
        .map_err(|_existing| "set_default_relays_for_test already installed".to_string())
}

/// Release-build stub for [`set_default_relays_for_test`].
///
/// Always returns an error so release callers fail closed — the override
/// path is physically unreachable here.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn set_default_relays_for_test(_relays: Vec<String>) -> Result<(), String> {
    Err("set_default_relays_for_test is disabled in release builds".to_string())
}

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
    ///
    /// Pending invitations are shown separately (via the invitations
    /// provider), so only accepted circles appear in the circle list.
    #[must_use]
    pub const fn is_visible(&self) -> bool {
        matches!(self, Self::Accepted)
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
#[derive(Clone)]
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

impl std::fmt::Debug for Contact {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Contact")
            .field(
                "pubkey",
                &format_args!("{}...", &self.pubkey[..16.min(self.pubkey.len())]),
            )
            .field("display_name", &"<redacted>")
            .field("avatar_path", &"<redacted>")
            .field("notes", &"<redacted>")
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .finish()
    }
}

/// A circle member with resolved local contact info.
///
/// When displaying circle members, this type combines the member's
/// pubkey with any locally-stored contact information.
#[derive(Clone)]
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

impl std::fmt::Debug for CircleMember {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleMember")
            .field(
                "pubkey",
                &format_args!("{}...", &self.pubkey[..16.min(self.pubkey.len())]),
            )
            .field("display_name", &"<redacted>")
            .field("avatar_path", &"<redacted>")
            .field("is_admin", &self.is_admin)
            .finish()
    }
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

/// A cached last-known location for a circle member.
///
/// Persisted in `CircleStorage` so the app can display each member's most
/// recent known position even when the relay has nothing fresh (e.g., member
/// is offline, or the kind:445 event has aged out of the relay). Access is
/// keyed by `(nostr_group_id, sender_pubkey)`.
///
/// # Privacy / retention
///
/// Receivers persistently cache last-known locations for a fixed
/// 1-day window (see `LOCATION_RETENTION_SECS`). The window is hard-coded
/// — senders cannot influence how long their stale location is retained
/// by other circle members. `purge_after` records the absolute moment
/// the row must be deleted; the receiver computes it on insert.
#[derive(Clone, PartialEq)]
pub struct LastKnownLocation {
    /// Nostr group ID of the circle this location belongs to.
    pub nostr_group_id: [u8; 32],
    /// Sender's Nostr public key (hex encoded).
    pub sender_pubkey: String,
    /// Latitude (exact GPS reading).
    pub latitude: f64,
    /// Longitude (exact GPS reading).
    pub longitude: f64,
    /// Geohash of the location.
    pub geohash: String,
    /// Display name carried in the encrypted location message, if any.
    pub display_name: Option<String>,
    /// When the location was captured (Unix seconds, from the sender's clock).
    pub timestamp: i64,
    /// When the inner freshness window expires (Unix seconds).
    pub expires_at: i64,
    /// Row must be deleted after this Unix-seconds moment.
    pub purge_after: i64,
    /// When this row was last written (Unix seconds, receiver's clock).
    pub updated_at: i64,
}

impl std::fmt::Debug for LastKnownLocation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LastKnownLocation")
            .field("nostr_group_id", &hex::encode(self.nostr_group_id))
            .field("sender_pubkey", &"<redacted>")
            .field("latitude", &"<redacted>")
            .field("longitude", &"<redacted>")
            .field("geohash", &"<redacted>")
            .field("display_name", &"<redacted>")
            .field("timestamp", &self.timestamp)
            .field("expires_at", &self.expires_at)
            .field("purge_after", &self.purge_after)
            .field("updated_at", &self.updated_at)
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

/// A member's key package with relay lists for Welcome delivery.
///
/// Used when adding members to a circle. Welcome delivery follows a
/// cascading fallback matching the Marmot Protocol reference implementation:
/// inbox relays (kind 10050) → NIP-65 relays (kind 10002) → default relays.
#[derive(Clone)]
pub struct MemberKeyPackage {
    /// The key package event (kind 30443 or legacy kind 443).
    pub key_package_event: nostr::Event,
    /// Relay URLs from the member's inbox relay list (kind 10050).
    /// First tier in the Welcome delivery cascade.
    pub inbox_relays: Vec<String>,
    /// Relay URLs from the member's NIP-65 relay list (kind 10002).
    /// Second tier, used when `inbox_relays` is empty.
    pub nip65_relays: Vec<String>,
}

impl std::fmt::Debug for MemberKeyPackage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemberKeyPackage")
            .field("key_package_event", &"<redacted>")
            .field("inbox_relays_count", &self.inbox_relays.len())
            .field("nip65_relays_count", &self.nip65_relays.len())
            .finish()
    }
}

/// A gift-wrapped Welcome ready for publishing.
///
/// Contains the kind 1059 gift-wrapped event along with recipient
/// information needed for relay publishing.
#[derive(Clone)]
pub struct GiftWrappedWelcome {
    /// The recipient's Nostr public key (hex).
    pub recipient_pubkey: String,
    /// Relay URLs to publish this Welcome to (recipient's inbox relays).
    pub recipient_relays: Vec<String>,
    /// The gift-wrapped event (kind 1059), ready to publish.
    pub event: nostr::Event,
}

impl std::fmt::Debug for GiftWrappedWelcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GiftWrappedWelcome")
            .field("recipient_pubkey", &"<redacted>")
            .field("relay_count", &self.recipient_relays.len())
            .field("event", &"<redacted>")
            .finish()
    }
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
        assert!(!MembershipStatus::Pending.is_visible());
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
            pubkey: "abc123def456789012345678".to_string(),
            display_name: Some("Bob".to_string()),
            avatar_path: None,
            is_admin: true,
        };

        let debug_str = format!("{:?}", member);
        assert!(debug_str.contains("CircleMember"));
        assert!(debug_str.contains("abc123def4567890..."));
        assert!(
            !debug_str.contains("Bob"),
            "display_name should be redacted"
        );
        assert!(debug_str.contains("<redacted>"));
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
            nip65_relays: vec!["wss://nip65.example.com".to_string()],
        };

        let debug_str = format!("{mkp:?}");
        assert!(debug_str.contains("MemberKeyPackage"));
        assert!(debug_str.contains("<redacted>"));
        assert!(debug_str.contains("inbox_relays_count: 1"));
        assert!(debug_str.contains("nip65_relays_count: 1"));
        assert!(
            !debug_str.contains("test-content"),
            "key_package_event content should be redacted"
        );
        assert!(
            !debug_str.contains("wss://relay.example.com"),
            "inbox relay URLs should not appear in debug output"
        );
        assert!(
            !debug_str.contains("wss://nip65.example.com"),
            "NIP-65 relay URLs should not appear in debug output"
        );
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
        assert!(
            !debug_str.contains("recipient-pubkey-hex"),
            "recipient_pubkey should be redacted"
        );
        assert!(debug_str.contains("<redacted>"));
        assert!(debug_str.contains("relay_count: 1"));
        assert!(
            !debug_str.contains("wrapped-content"),
            "event content should be redacted"
        );
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
    fn production_default_relays_constant() {
        assert!(!PRODUCTION_DEFAULT_RELAYS.is_empty());
        for relay in PRODUCTION_DEFAULT_RELAYS {
            assert!(relay.starts_with("wss://"));
        }
    }

    #[test]
    fn default_relays_returns_production_list_by_default() {
        // No override installed in this test process (set_default_relays_for_test
        // is install-once and may have run in a sibling test; if it has, the
        // returned list is the override and we cannot assert equality with the
        // production constant. Either way the returned list must be non-empty
        // and contain only wss:// URLs).
        let relays = default_relays();
        assert!(!relays.is_empty());
        for relay in &relays {
            assert!(
                relay.starts_with("wss://") || relay.starts_with("ws://"),
                "unexpected scheme in {relay}"
            );
        }
    }

    #[test]
    fn set_default_relays_for_test_rejects_empty_list() {
        // Empty input must be rejected without touching the OnceLock.
        let err = set_default_relays_for_test(vec![]).expect_err("empty input must error");
        assert!(err.to_lowercase().contains("non-empty"));
    }
}
