//! API bridging layer that exposes haven-core functionality.

use std::collections::HashMap;
use std::sync::RwLock;

use flutter_rust_bridge::frb;
pub use haven_core::location::LocationPrecision;
use haven_core::nostr::identity::{
    IdentityError, IdentityManager, PublicIdentity as CorePublicIdentity,
    SecureKeyStorage as CoreSecureKeyStorage,
};

/// Core interface for Haven functionality (wrapper around haven-core).
#[derive(Debug, Default)]
#[frb(opaque)]
pub struct HavenCore {
    inner: haven_core::HavenCore,
}

impl HavenCore {
    /// Creates a new `HavenCore` instance.
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: haven_core::HavenCore::new(),
        }
    }

    /// Returns whether the core has been initialized.
    #[must_use]
    #[frb(sync)]
    pub fn is_initialized(&self) -> bool {
        self.inner.is_initialized()
    }

    /// Initializes the core.
    pub fn initialize(&mut self) -> Result<(), String> {
        self.inner.initialize()
    }

    /// Processes raw location data and returns an obfuscated `LocationMessage`.
    #[frb(sync)]
    pub fn update_location(&self, latitude: f64, longitude: f64) -> LocationMessage {
        let msg = self.inner.update_location(latitude, longitude);
        LocationMessage { inner: msg }
    }

    /// Gets the current location settings.
    #[frb(sync)]
    pub fn get_location_settings(&self) -> LocationSettings {
        let settings = self.inner.get_location_settings();
        LocationSettings { inner: settings }
    }

    /// Updates the location settings.
    #[frb(sync)]
    pub fn set_location_settings(&mut self, settings: LocationSettings) {
        self.inner.set_location_settings(settings.inner);
    }
}

/// Location message with obfuscated coordinates (FFI wrapper).
#[derive(Debug, Clone)]
#[frb(opaque)]
pub struct LocationMessage {
    inner: haven_core::location::LocationMessage,
}

impl LocationMessage {
    /// Gets the obfuscated latitude.
    #[frb(sync)]
    #[must_use]
    pub fn latitude(&self) -> f64 {
        self.inner.latitude
    }

    /// Gets the obfuscated longitude.
    #[frb(sync)]
    #[must_use]
    pub fn longitude(&self) -> f64 {
        self.inner.longitude
    }

    /// Gets the geohash representation.
    #[frb(sync)]
    #[must_use]
    pub fn geohash(&self) -> String {
        self.inner.geohash.clone()
    }

    /// Gets the timestamp as Unix timestamp (seconds since epoch).
    #[frb(sync)]
    #[must_use]
    pub fn timestamp(&self) -> i64 {
        self.inner.timestamp.timestamp()
    }

    /// Gets the expiration time as Unix timestamp (seconds since epoch).
    #[frb(sync)]
    #[must_use]
    pub fn expires_at(&self) -> i64 {
        self.inner.expires_at.timestamp()
    }

    /// Gets the precision level.
    #[frb(sync)]
    #[must_use]
    pub fn precision(&self) -> LocationPrecision {
        self.inner.precision
    }

    /// Checks if the location has expired.
    #[frb(sync)]
    #[must_use]
    pub fn is_expired(&self) -> bool {
        self.inner.is_expired()
    }
}

/// Location settings (FFI wrapper).
#[derive(Debug, Clone)]
#[frb(opaque)]
pub struct LocationSettings {
    inner: haven_core::location::LocationSettings,
}

impl LocationSettings {
    /// Creates new location settings.
    #[must_use]
    pub fn new(
        precision: LocationPrecision,
        update_interval_minutes: u32,
        include_geohash_in_events: bool,
    ) -> Self {
        Self {
            inner: haven_core::location::LocationSettings {
                precision,
                update_interval_minutes,
                include_geohash_in_events,
            },
        }
    }

    /// Gets the precision level.
    #[frb(sync)]
    #[must_use]
    pub fn precision(&self) -> LocationPrecision {
        self.inner.precision
    }

    /// Gets the update interval in minutes.
    #[frb(sync)]
    #[must_use]
    pub fn update_interval_minutes(&self) -> u32 {
        self.inner.update_interval_minutes
    }

    /// Gets whether to include geohash in events.
    #[frb(sync)]
    #[must_use]
    pub fn include_geohash_in_events(&self) -> bool {
        self.inner.include_geohash_in_events
    }
}

// ============================================================================
// Identity Management
// ============================================================================

/// In-memory secure storage for FFI.
///
/// Flutter should call `store_secret` with data from `flutter_secure_storage`
/// after loading, and call `get_secret_for_storage` before persisting.
#[derive(Debug, Default)]
#[frb(ignore)]
struct InMemoryStorage {
    data: RwLock<HashMap<String, Vec<u8>>>,
}

impl CoreSecureKeyStorage for InMemoryStorage {
    fn store(&self, key: &str, value: &[u8]) -> Result<(), IdentityError> {
        use zeroize::Zeroize;

        let mut data = self
            .data
            .write()
            .map_err(|e| IdentityError::Storage(e.to_string()))?;
        // Zeroize the displaced value (if any) before it is dropped
        if let Some(mut old) = data.insert(key.to_string(), value.to_vec()) {
            old.zeroize();
        }
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<Vec<u8>>, IdentityError> {
        let data = self
            .data
            .read()
            .map_err(|e| IdentityError::Storage(e.to_string()))?;
        Ok(data.get(key).cloned())
    }

    fn delete(&self, key: &str) -> Result<(), IdentityError> {
        use zeroize::Zeroize;

        let mut data = self
            .data
            .write()
            .map_err(|e| IdentityError::Storage(e.to_string()))?;
        // Zeroize the removed value before it is dropped
        if let Some(mut old) = data.remove(key) {
            old.zeroize();
        }
        Ok(())
    }

    fn exists(&self, key: &str) -> Result<bool, IdentityError> {
        let data = self
            .data
            .read()
            .map_err(|e| IdentityError::Storage(e.to_string()))?;
        Ok(data.contains_key(key))
    }
}

/// Public identity information (FFI-friendly).
///
/// Contains only public data that can be safely stored and shared.
#[derive(Debug, Clone)]
pub struct PublicIdentity {
    /// Public key as 64-character hex string.
    pub pubkey_hex: String,
    /// Public key in NIP-19 bech32 format (npub1...).
    pub npub: String,
    /// When this identity was created (Unix timestamp).
    pub created_at: i64,
}

impl From<CorePublicIdentity> for PublicIdentity {
    fn from(inner: CorePublicIdentity) -> Self {
        Self {
            pubkey_hex: inner.pubkey_hex,
            npub: inner.npub,
            created_at: inner.created_at.timestamp(),
        }
    }
}

/// Nostr identity manager (FFI wrapper).
///
/// Manages the user's persistent Nostr identity (nsec/npub).
///
/// # Usage Flow
///
/// 1. Create manager with `NostrIdentityManager::new()`
/// 2. Load persisted secret from Flutter secure storage (if exists)
/// 3. Call `load_from_bytes()` to restore the identity
/// 4. Or call `create_identity()` to generate a new one
/// 5. Before app exits, get secret bytes with `get_secret_bytes()` and persist in Flutter
#[frb(opaque)]
pub struct NostrIdentityManager {
    inner: IdentityManager<InMemoryStorage>,
}

impl NostrIdentityManager {
    /// Creates a new identity manager.
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: IdentityManager::new(InMemoryStorage::default()),
        }
    }

    /// Loads an identity from raw secret bytes (retrieved from Flutter secure storage).
    ///
    /// Call this on app startup if you have persisted secret bytes.
    pub fn load_from_bytes(&self, secret_bytes: Vec<u8>) -> Result<PublicIdentity, String> {
        // Store and validate the secret bytes
        self.inner
            .store_secret_bytes(&secret_bytes)
            .map_err(|e| e.to_string())?;

        // Get the identity
        self.inner
            .get_identity()
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Failed to load identity".to_string())
            .map(Into::into)
    }

    /// Checks if an identity is loaded.
    #[frb(sync)]
    #[must_use]
    pub fn has_identity(&self) -> bool {
        self.inner.has_identity().unwrap_or(false)
    }

    /// Creates a new random identity.
    ///
    /// After calling this, use `get_secret_bytes()` to persist the secret.
    pub fn create_identity(&self) -> Result<PublicIdentity, String> {
        self.inner
            .create_identity()
            .map(Into::into)
            .map_err(|e| e.to_string())
    }

    /// Imports an identity from an nsec string.
    ///
    /// After calling this, use `get_secret_bytes()` to persist the secret.
    pub fn import_from_nsec(&self, nsec: String) -> Result<PublicIdentity, String> {
        self.inner
            .import_from_nsec(&nsec)
            .map(Into::into)
            .map_err(|e| e.to_string())
    }

    /// Gets the current public identity.
    #[frb(sync)]
    pub fn get_identity(&self) -> Result<Option<PublicIdentity>, String> {
        self.inner
            .get_identity()
            .map(|opt| opt.map(Into::into))
            .map_err(|e| e.to_string())
    }

    /// Gets the public key as hex string (for MDK operations).
    #[frb(sync)]
    pub fn pubkey_hex(&self) -> Result<String, String> {
        self.inner.pubkey_hex().map_err(|e| e.to_string())
    }

    /// Exports the identity as nsec for backup.
    ///
    /// # Security Warning
    ///
    /// This exposes the secret key. Only use for user-initiated backup.
    pub fn export_nsec(&self) -> Result<String, String> {
        self.inner.export_nsec().map_err(|e| e.to_string())
    }

    /// Signs a 32-byte message hash.
    ///
    /// Returns the signature as a 128-character hex string.
    pub fn sign(&self, message_hash: Vec<u8>) -> Result<String, String> {
        if message_hash.len() != 32 {
            return Err(format!(
                "Invalid message hash length: expected 32, got {}",
                message_hash.len()
            ));
        }

        let mut hash = [0u8; 32];
        hash.copy_from_slice(&message_hash);

        self.inner.sign(&hash).map_err(|e| e.to_string())
    }

    /// Gets the secret bytes for persistence in Flutter secure storage.
    ///
    /// # Security Warning
    ///
    /// Handle these bytes with extreme care. They should only be stored
    /// in platform secure storage (iOS Keychain, Android Keystore, etc.).
    /// The bytes are automatically zeroized in Rust memory after this call.
    pub fn get_secret_bytes(&self) -> Result<Vec<u8>, String> {
        // The inner method returns Zeroizing<Vec<u8>>, we extract the bytes
        // for FFI. Flutter must handle these securely.
        self.inner
            .get_secret_bytes()
            .map(|z| z.to_vec())
            .map_err(|e| e.to_string())
    }

    /// Deletes the identity.
    pub fn delete_identity(&self) -> Result<(), String> {
        self.inner.delete_identity().map_err(|e| e.to_string())
    }

    /// Clears the in-memory cache.
    ///
    /// Call this when the app goes to background.
    pub fn clear_cache(&self) {
        // Ignore lock errors - if the lock is poisoned, the data is already gone
        let _ = self.inner.clear_cache();
    }
}

impl Default for NostrIdentityManager {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for NostrIdentityManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NostrIdentityManager")
            .field("has_identity", &self.has_identity())
            .finish()
    }
}

// ============================================================================
// Encrypted Event Types (FFI wrappers for Nostr event generation)
// ============================================================================

/// Unsigned location event (FFI wrapper for inner event kind 30078).
///
/// This is the inner event containing location data before encryption.
/// It is wrapped in a kind 445 group message for transmission.
#[derive(Debug, Clone)]
pub struct UnsignedLocationEventFfi {
    /// Event kind (30078 for location data).
    pub kind: u16,
    /// JSON-serialized location data.
    pub content: String,
    /// Event tags (typically empty for inner events).
    pub tags: Vec<Vec<String>>,
    /// Unix timestamp when the event was created.
    pub created_at: i64,
}

impl From<haven_core::nostr::UnsignedLocationEvent> for UnsignedLocationEventFfi {
    fn from(e: haven_core::nostr::UnsignedLocationEvent) -> Self {
        Self {
            kind: e.kind,
            content: e.content,
            tags: e.tags,
            created_at: e.created_at,
        }
    }
}

/// Signed location event (FFI wrapper for outer event kind 445).
///
/// This is the outer event ready for relay transmission.
/// Contains encrypted content signed with an ephemeral keypair.
#[derive(Debug, Clone)]
pub struct SignedLocationEventFfi {
    /// Event ID (SHA256 hash, 64 hex chars).
    pub id: String,
    /// Ephemeral public key (64 hex chars).
    pub pubkey: String,
    /// Unix timestamp when the event was created.
    pub created_at: i64,
    /// Event kind (445 for Marmot group messages).
    pub kind: u16,
    /// Event tags: `[["h", group_id], ["expiration", ts], ...]`.
    pub tags: Vec<Vec<String>>,
    /// NIP-44 encrypted content (base64).
    pub content: String,
    /// Schnorr signature (128 hex chars).
    pub sig: String,
}

impl From<haven_core::nostr::SignedLocationEvent> for SignedLocationEventFfi {
    fn from(e: haven_core::nostr::SignedLocationEvent) -> Self {
        Self {
            id: e.id,
            pubkey: e.pubkey,
            created_at: e.created_at,
            kind: e.kind,
            tags: e.tags,
            content: e.content,
            sig: e.sig,
        }
    }
}

// ============================================================================
// Location Event Service
// ============================================================================

/// Service for creating and verifying Nostr location events.
///
/// Provides methods for creating unsigned Nostr events from location data
/// and verifying signatures on signed events.
#[derive(Debug, Default)]
#[frb(opaque)]
pub struct LocationEventService {
    _private: (),
}

impl LocationEventService {
    /// Creates a new `LocationEventService`.
    #[must_use]
    pub fn new() -> Self {
        Self { _private: () }
    }

    /// Creates an unsigned location event (kind 30078).
    ///
    /// This is the inner event that gets encrypted before being wrapped
    /// in a kind 445 group message.
    #[frb(sync)]
    pub fn create_unsigned_event(
        &self,
        location: &LocationMessage,
    ) -> Result<UnsignedLocationEventFfi, String> {
        haven_core::nostr::UnsignedLocationEvent::from_location(&location.inner)
            .map(Into::into)
            .map_err(|e| e.to_string())
    }

    /// Verifies the signature of a signed event.
    ///
    /// Returns `true` if the signature is valid, `false` otherwise.
    #[frb(sync)]
    pub fn verify_signature(&self, event: &SignedLocationEventFfi) -> Result<bool, String> {
        let core_event = haven_core::nostr::SignedLocationEvent {
            id: event.id.clone(),
            pubkey: event.pubkey.clone(),
            created_at: event.created_at,
            kind: event.kind,
            tags: event.tags.clone(),
            content: event.content.clone(),
            sig: event.sig.clone(),
        };

        match core_event.verify_signature() {
            Ok(()) => Ok(true),
            Err(_) => Ok(false),
        }
    }
}

// ============================================================================
// Circle Management (FFI)
// ============================================================================

use std::path::Path;

use haven_core::circle::{
    Circle as CoreCircle, CircleConfig as CoreCircleConfig, CircleManager as CoreCircleManager,
    CircleMember as CoreCircleMember, CircleType as CoreCircleType,
    CircleWithMembers as CoreCircleWithMembers, Contact as CoreContact,
    Invitation as CoreInvitation,
};
use haven_core::nostr::mls::types::{GroupId, KeyPackageBundle as CoreKeyPackageBundle};

/// Circle information (FFI-friendly).
///
/// Represents a location sharing circle (group of people).
#[derive(Clone)]
pub struct CircleFfi {
    /// MLS group ID (opaque bytes, used for API calls).
    pub mls_group_id: Vec<u8>,
    /// Nostr group ID (32 bytes, used in h-tags for relay routing).
    pub nostr_group_id: Vec<u8>,
    /// User-facing display name (local only).
    pub display_name: String,
    /// Circle type: "location_sharing" or "direct_share".
    pub circle_type: String,
    /// Relay URLs for this circle's messages.
    pub relays: Vec<String>,
    /// When the circle was created (Unix timestamp).
    pub created_at: i64,
    /// When the circle was last updated (Unix timestamp).
    pub updated_at: i64,
}

impl std::fmt::Debug for CircleFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleFfi")
            .field("mls_group_id", &"<redacted>")
            .field(
                "nostr_group_id",
                &self
                    .nostr_group_id
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>(),
            )
            .field("display_name", &self.display_name)
            .field("circle_type", &self.circle_type)
            .field("relays", &self.relays)
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .finish()
    }
}

impl From<&CoreCircle> for CircleFfi {
    fn from(c: &CoreCircle) -> Self {
        Self {
            mls_group_id: c.mls_group_id.as_slice().to_vec(),
            nostr_group_id: c.nostr_group_id.to_vec(),
            display_name: c.display_name.clone(),
            circle_type: c.circle_type.as_str().to_string(),
            relays: c.relays.clone(),
            created_at: c.created_at,
            updated_at: c.updated_at,
        }
    }
}

/// Local contact information (FFI-friendly).
///
/// **Privacy Note**: This data is stored only on the user's device,
/// never synced to Nostr relays. Each user assigns their own names
/// and avatars to contacts (like phone contacts).
#[derive(Debug, Clone)]
pub struct ContactFfi {
    /// Nostr public key (hex) - the ONLY identifier visible to relays.
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

impl From<&CoreContact> for ContactFfi {
    fn from(c: &CoreContact) -> Self {
        Self {
            pubkey: c.pubkey.clone(),
            display_name: c.display_name.clone(),
            avatar_path: c.avatar_path.clone(),
            notes: c.notes.clone(),
            created_at: c.created_at,
            updated_at: c.updated_at,
        }
    }
}

impl From<CoreContact> for ContactFfi {
    fn from(c: CoreContact) -> Self {
        Self::from(&c)
    }
}

/// Circle member with resolved local contact info (FFI-friendly).
#[derive(Debug, Clone)]
pub struct CircleMemberFfi {
    /// Nostr public key (hex) - always available.
    pub pubkey: String,
    /// Display name from local Contact, if set.
    pub display_name: Option<String>,
    /// Avatar path from local Contact, if set.
    pub avatar_path: Option<String>,
    /// Whether this member is a group admin.
    pub is_admin: bool,
}

impl From<&CoreCircleMember> for CircleMemberFfi {
    fn from(m: &CoreCircleMember) -> Self {
        Self {
            pubkey: m.pubkey.clone(),
            display_name: m.display_name.clone(),
            avatar_path: m.avatar_path.clone(),
            is_admin: m.is_admin,
        }
    }
}

/// Circle with its membership and member list (FFI-friendly).
#[derive(Debug, Clone)]
pub struct CircleWithMembersFfi {
    /// The circle.
    pub circle: CircleFfi,
    /// User's membership status: "pending", "accepted", or "declined".
    pub membership_status: String,
    /// Public key of who invited us (if known).
    pub inviter_pubkey: Option<String>,
    /// Members with resolved contact info.
    pub members: Vec<CircleMemberFfi>,
}

impl From<&CoreCircleWithMembers> for CircleWithMembersFfi {
    fn from(c: &CoreCircleWithMembers) -> Self {
        Self {
            circle: CircleFfi::from(&c.circle),
            membership_status: c.membership.status.as_str().to_string(),
            inviter_pubkey: c.membership.inviter_pubkey.clone(),
            members: c.members.iter().map(CircleMemberFfi::from).collect(),
        }
    }
}

/// Pending invitation to join a circle (FFI-friendly).
#[derive(Clone)]
pub struct InvitationFfi {
    /// MLS group ID.
    pub mls_group_id: Vec<u8>,
    /// Circle name.
    pub circle_name: String,
    /// Public key (hex) of who invited us.
    pub inviter_pubkey: String,
    /// Number of members in the circle.
    pub member_count: u32,
    /// When we were invited (Unix timestamp).
    pub invited_at: i64,
}

impl std::fmt::Debug for InvitationFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InvitationFfi")
            .field("mls_group_id", &"<redacted>")
            .field("circle_name", &self.circle_name)
            .field("inviter_pubkey", &self.inviter_pubkey)
            .field("member_count", &self.member_count)
            .field("invited_at", &self.invited_at)
            .finish()
    }
}

impl From<&CoreInvitation> for InvitationFfi {
    fn from(i: &CoreInvitation) -> Self {
        Self {
            mls_group_id: i.mls_group_id.as_slice().to_vec(),
            circle_name: i.circle_name.clone(),
            inviter_pubkey: i.inviter_pubkey.clone(),
            member_count: i.member_count as u32,
            invited_at: i.invited_at,
        }
    }
}

impl From<CoreInvitation> for InvitationFfi {
    fn from(i: CoreInvitation) -> Self {
        Self::from(&i)
    }
}

/// Key package bundle for publishing (FFI-friendly).
///
/// Contains the data needed to build a kind 443 Nostr event.
#[derive(Debug, Clone)]
pub struct KeyPackageBundleFfi {
    /// Hex-encoded serialized key package (event content).
    pub content: String,
    /// Tags to include in the event.
    pub tags: Vec<Vec<String>>,
    /// Relay URLs where this key package will be published.
    pub relays: Vec<String>,
}

impl From<CoreKeyPackageBundle> for KeyPackageBundleFfi {
    fn from(b: CoreKeyPackageBundle) -> Self {
        Self {
            content: b.content,
            tags: b.tags,
            relays: b.relays,
        }
    }
}

/// A member's key package with their inbox relay list (FFI-friendly).
///
/// Used when adding members to a circle. The inbox relays are fetched
/// from the member's kind 10051 relay list and used for publishing
/// the gift-wrapped Welcome.
#[derive(Debug, Clone)]
pub struct MemberKeyPackageFfi {
    /// The key package event JSON (kind 443).
    pub key_package_json: String,
    /// Relay URLs where the Welcome should be sent (from kind 10051).
    pub inbox_relays: Vec<String>,
}

/// A gift-wrapped Welcome ready for publishing (FFI-friendly).
///
/// Contains the kind 1059 gift-wrapped event along with recipient
/// information needed for relay publishing.
#[derive(Debug, Clone)]
pub struct GiftWrappedWelcomeFfi {
    /// The recipient's Nostr public key (hex).
    pub recipient_pubkey: String,
    /// Relay URLs to publish this Welcome to (recipient's inbox relays).
    pub recipient_relays: Vec<String>,
    /// The gift-wrapped event JSON (kind 1059), ready to publish.
    pub event_json: String,
}

/// Result of circle creation (FFI-friendly).
#[derive(Debug, Clone)]
pub struct CircleCreationResultFfi {
    /// The created circle.
    pub circle: CircleFfi,
    /// Gift-wrapped Welcome events ready to publish to recipients.
    /// Each is a kind 1059 event containing an encrypted kind 444 Welcome.
    pub welcome_events: Vec<GiftWrappedWelcomeFfi>,
}

/// Unsigned Nostr event (FFI-friendly).
///
/// Generic unsigned event for FFI use.
#[derive(Debug, Clone)]
pub struct UnsignedEventFfi {
    /// Event kind.
    pub kind: u16,
    /// Event content.
    pub content: String,
    /// Event tags.
    pub tags: Vec<Vec<String>>,
    /// Unix timestamp when the event was created.
    pub created_at: i64,
    /// Public key (hex) of the event creator (may be empty for unsigned).
    pub pubkey: String,
}

/// Generic signed event for FFI use.
#[derive(Debug, Clone)]
pub struct SignedEventFfi {
    /// Event ID (hex).
    pub id: String,
    /// Event kind.
    pub kind: u16,
    /// Event content.
    pub content: String,
    /// Event tags.
    pub tags: Vec<Vec<String>>,
    /// Unix timestamp when the event was created.
    pub created_at: i64,
    /// Public key (hex) of the event creator.
    pub pubkey: String,
    /// Signature (hex).
    pub sig: String,
}

/// Update group result (FFI-friendly).
///
/// Returned after add/remove members or leave operations.
#[derive(Debug, Clone)]
pub struct UpdateGroupResultFfi {
    /// Evolution event (kind 445) to publish to the group relays.
    pub evolution_event: SignedEventFfi,
    /// Welcome events (kind 444) for newly added members (if any).
    pub welcome_events: Vec<UnsignedEventFfi>,
}

/// Circle manager (FFI wrapper).
///
/// High-level API for managing circles (location sharing groups).
/// Combines MLS operations with local storage for circle metadata
/// and contact information.
///
/// # Privacy Model
///
/// Haven uses a privacy-first approach:
/// - User profiles (kind 0) are never published to relays
/// - Contact info (display names, avatars) is stored locally only
/// - Relays only see pubkeys, never usernames
///
/// # Thread Safety
///
/// This type is thread-safe via internal async `Mutex`. The underlying SQLite
/// connections are not `Sync`, so we protect access with a mutex.
#[frb(opaque)]
pub struct CircleManagerFfi {
    inner: tokio::sync::Mutex<CoreCircleManager>,
}

impl CircleManagerFfi {
    /// Creates a new circle manager.
    ///
    /// Initializes both MLS storage and circle metadata database
    /// at the given data directory.
    pub fn new(data_dir: String) -> Result<Self, String> {
        let path = Path::new(&data_dir);
        CoreCircleManager::new(path)
            .map(|inner| Self {
                inner: tokio::sync::Mutex::new(inner),
            })
            .map_err(|e| e.to_string())
    }

    // ==================== Circle Lifecycle ====================

    /// Creates a new circle with gift-wrapped Welcome events.
    ///
    /// Returns the created circle and gift-wrapped Welcome events ready
    /// to publish to the invited members' inbox relays.
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The creator's identity secret bytes (32 bytes,
    ///   from `NostrIdentityManager.get_secret_bytes()`)
    /// * `members` - Key packages and inbox relays for each member
    /// * `name` - Circle name
    /// * `description` - Optional circle description
    /// * `circle_type` - Circle type: "location_sharing" or "direct_share"
    /// * `relays` - Relay URLs for the circle's messages
    ///
    /// # Security
    ///
    /// The Welcome events are gift-wrapped per NIP-59, hiding the sender's
    /// identity behind an ephemeral key. Each Welcome uses a fresh ephemeral
    /// keypair and randomized timestamp.
    pub async fn create_circle(
        &self,
        identity_secret_bytes: Vec<u8>,
        members: Vec<MemberKeyPackageFfi>,
        name: String,
        description: Option<String>,
        circle_type: String,
        relays: Vec<String>,
    ) -> Result<CircleCreationResultFfi, String> {
        // Construct Keys from secret bytes
        if identity_secret_bytes.len() != 32 {
            return Err(format!(
                "Invalid secret bytes length: expected 32, got {}",
                identity_secret_bytes.len()
            ));
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        // Parse member key packages
        let member_key_packages: Vec<haven_core::circle::MemberKeyPackage> = members
            .into_iter()
            .map(|m| {
                let key_package_event: nostr::Event = serde_json::from_str(&m.key_package_json)
                    .map_err(|e| format!("Invalid key package JSON: {e}"))?;
                Ok(haven_core::circle::MemberKeyPackage {
                    key_package_event,
                    inbox_relays: m.inbox_relays,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;

        // Parse circle type
        let ct = CoreCircleType::parse(&circle_type)
            .ok_or_else(|| format!("Invalid circle type: {circle_type}"))?;

        let config = CoreCircleConfig::new(&name)
            .with_type(ct)
            .with_relays(relays);

        let config = if let Some(desc) = description {
            config.with_description(desc)
        } else {
            config
        };

        let guard = self.inner.lock().await;
        let result = guard
            .create_circle(&keys, member_key_packages, &config)
            .await
            .map_err(|e| e.to_string())?;

        // Convert gift-wrapped welcome events to FFI
        let welcome_events: Vec<GiftWrappedWelcomeFfi> = result
            .welcome_events
            .into_iter()
            .map(|w| {
                let event_json =
                    serde_json::to_string(&w.event).expect("Failed to serialize event");
                GiftWrappedWelcomeFfi {
                    recipient_pubkey: w.recipient_pubkey,
                    recipient_relays: w.recipient_relays,
                    event_json,
                }
            })
            .collect();

        Ok(CircleCreationResultFfi {
            circle: CircleFfi::from(&result.circle),
            welcome_events,
        })
    }

    /// Gets a circle by its MLS group ID.
    pub async fn get_circle(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<Option<CircleWithMembersFfi>, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let guard = self.inner.lock().await;
        guard
            .get_circle(&group_id)
            .map(|opt| opt.map(|c| CircleWithMembersFfi::from(&c)))
            .map_err(|e| e.to_string())
    }

    /// Gets all circles.
    pub async fn get_circles(&self) -> Result<Vec<CircleWithMembersFfi>, String> {
        let guard = self.inner.lock().await;
        guard
            .get_circles()
            .map(|circles| circles.iter().map(CircleWithMembersFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Gets visible circles (excludes declined invitations).
    pub async fn get_visible_circles(&self) -> Result<Vec<CircleWithMembersFfi>, String> {
        let guard = self.inner.lock().await;
        guard
            .get_visible_circles()
            .map(|circles| circles.iter().map(CircleWithMembersFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Leaves a circle.
    ///
    /// Returns the update result with evolution events to publish.
    pub async fn leave_circle(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let guard = self.inner.lock().await;
        let result = guard.leave_circle(&group_id).map_err(|e| e.to_string())?;

        // Convert evolution event (signed Event -> SignedEventFfi)
        let e = result.evolution_event;
        let evolution_event = SignedEventFfi {
            id: e.id.to_hex(),
            kind: e.kind.as_u16(),
            content: e.content.to_string(),
            tags: e
                .tags
                .iter()
                .map(|t: &nostr::Tag| t.as_slice().iter().map(ToString::to_string).collect())
                .collect(),
            created_at: e.created_at.as_secs() as i64,
            pubkey: e.pubkey.to_hex(),
            sig: e.sig.to_string(),
        };

        // Convert welcome events (Option<Vec<UnsignedEvent>> -> Vec<UnsignedEventFfi>)
        let welcome_events: Vec<UnsignedEventFfi> = result
            .welcome_rumors
            .unwrap_or_default()
            .into_iter()
            .map(|e| UnsignedEventFfi {
                kind: e.kind.as_u16(),
                content: e.content.to_string(),
                tags: e
                    .tags
                    .iter()
                    .map(|t: &nostr::Tag| t.as_slice().iter().map(ToString::to_string).collect())
                    .collect(),
                created_at: e.created_at.as_secs() as i64,
                pubkey: e.pubkey.to_hex(),
            })
            .collect();

        Ok(UpdateGroupResultFfi {
            evolution_event,
            welcome_events,
        })
    }

    // ==================== Member Management ====================

    /// Adds members to a circle.
    ///
    /// Returns the update result with evolution and welcome events.
    pub async fn add_members(
        &self,
        mls_group_id: Vec<u8>,
        key_packages_json: Vec<String>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);

        // Parse key packages from JSON
        let key_packages: Vec<nostr::Event> = key_packages_json
            .iter()
            .map(|json| {
                serde_json::from_str(json).map_err(|e| format!("Invalid key package JSON: {e}"))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let guard = self.inner.lock().await;
        let result = guard
            .add_members(&group_id, &key_packages)
            .map_err(|e| e.to_string())?;

        // Convert evolution event (signed Event -> SignedEventFfi)
        let e = result.evolution_event;
        let evolution_event = SignedEventFfi {
            id: e.id.to_hex(),
            kind: e.kind.as_u16(),
            content: e.content.to_string(),
            tags: e
                .tags
                .iter()
                .map(|t: &nostr::Tag| t.as_slice().iter().map(ToString::to_string).collect())
                .collect(),
            created_at: e.created_at.as_secs() as i64,
            pubkey: e.pubkey.to_hex(),
            sig: e.sig.to_string(),
        };

        // Convert welcome events (Option<Vec<UnsignedEvent>> -> Vec<UnsignedEventFfi>)
        let welcome_events: Vec<UnsignedEventFfi> = result
            .welcome_rumors
            .unwrap_or_default()
            .into_iter()
            .map(|e| UnsignedEventFfi {
                kind: e.kind.as_u16(),
                content: e.content.to_string(),
                tags: e
                    .tags
                    .iter()
                    .map(|t: &nostr::Tag| t.as_slice().iter().map(ToString::to_string).collect())
                    .collect(),
                created_at: e.created_at.as_secs() as i64,
                pubkey: e.pubkey.to_hex(),
            })
            .collect();

        Ok(UpdateGroupResultFfi {
            evolution_event,
            welcome_events,
        })
    }

    /// Removes members from a circle.
    ///
    /// Returns the update result with evolution events.
    pub async fn remove_members(
        &self,
        mls_group_id: Vec<u8>,
        member_pubkeys: Vec<String>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);

        let guard = self.inner.lock().await;
        let result = guard
            .remove_members(&group_id, &member_pubkeys)
            .map_err(|e| e.to_string())?;

        // Convert evolution event (signed Event -> SignedEventFfi)
        let e = result.evolution_event;
        let evolution_event = SignedEventFfi {
            id: e.id.to_hex(),
            kind: e.kind.as_u16(),
            content: e.content.to_string(),
            tags: e
                .tags
                .iter()
                .map(|t: &nostr::Tag| t.as_slice().iter().map(ToString::to_string).collect())
                .collect(),
            created_at: e.created_at.as_secs() as i64,
            pubkey: e.pubkey.to_hex(),
            sig: e.sig.to_string(),
        };

        Ok(UpdateGroupResultFfi {
            evolution_event,
            welcome_events: Vec::new(),
        })
    }

    /// Gets members of a circle with resolved contact info.
    pub async fn get_members(&self, mls_group_id: Vec<u8>) -> Result<Vec<CircleMemberFfi>, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let guard = self.inner.lock().await;
        guard
            .get_members(&group_id)
            .map(|members| members.iter().map(CircleMemberFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    // ==================== Contact Management ====================

    /// Sets or updates a contact.
    ///
    /// Contact information is stored locally only and never synced to relays.
    pub async fn set_contact(
        &self,
        pubkey: String,
        display_name: Option<String>,
        avatar_path: Option<String>,
        notes: Option<String>,
    ) -> Result<ContactFfi, String> {
        let guard = self.inner.lock().await;
        guard
            .set_contact(
                &pubkey,
                display_name.as_deref(),
                avatar_path.as_deref(),
                notes.as_deref(),
            )
            .map(ContactFfi::from)
            .map_err(|e| e.to_string())
    }

    /// Gets a contact by pubkey.
    pub async fn get_contact(&self, pubkey: String) -> Result<Option<ContactFfi>, String> {
        let guard = self.inner.lock().await;
        guard
            .get_contact(&pubkey)
            .map(|opt| opt.map(ContactFfi::from))
            .map_err(|e| e.to_string())
    }

    /// Gets all contacts.
    pub async fn get_all_contacts(&self) -> Result<Vec<ContactFfi>, String> {
        let guard = self.inner.lock().await;
        guard
            .get_all_contacts()
            .map(|contacts| contacts.into_iter().map(ContactFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Deletes a contact.
    pub async fn delete_contact(&self, pubkey: String) -> Result<(), String> {
        let guard = self.inner.lock().await;
        guard.delete_contact(&pubkey).map_err(|e| e.to_string())
    }

    // ==================== Invitation Handling ====================

    /// Processes a gift-wrapped Welcome event (kind 1059).
    ///
    /// This is the high-level API for processing incoming invitations.
    /// It unwraps the gift-wrapped event, extracts the sender info,
    /// and processes the invitation.
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The recipient's identity secret bytes (32 bytes)
    /// * `gift_wrap_event_json` - The kind 1059 gift-wrapped event JSON
    /// * `circle_name` - Name of the circle (from invitation metadata)
    ///
    /// # Returns
    ///
    /// The pending invitation, which can be accepted or declined.
    pub async fn process_gift_wrapped_invitation(
        &self,
        identity_secret_bytes: Vec<u8>,
        gift_wrap_event_json: String,
        circle_name: String,
    ) -> Result<InvitationFfi, String> {
        // Construct Keys from secret bytes
        if identity_secret_bytes.len() != 32 {
            return Err(format!(
                "Invalid secret bytes length: expected 32, got {}",
                identity_secret_bytes.len()
            ));
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        // Parse the gift-wrapped event
        let gift_wrap_event: nostr::Event = serde_json::from_str(&gift_wrap_event_json)
            .map_err(|e| format!("Invalid gift wrap event JSON: {e}"))?;

        let guard = self.inner.lock().await;
        guard
            .process_gift_wrapped_invitation(&keys, &gift_wrap_event, &circle_name)
            .await
            .map(InvitationFfi::from)
            .map_err(|e| e.to_string())
    }

    /// Processes an incoming invitation from already-unwrapped components.
    ///
    /// This is the low-level API that takes pre-unwrapped components.
    /// Prefer [`process_gift_wrapped_invitation`] for most use cases.
    ///
    /// # Arguments
    ///
    /// * `wrapper_event_id` - ID of the gift-wrapped event (hex)
    /// * `rumor_event_json` - The decrypted kind 444 rumor event JSON
    /// * `circle_name` - Name of the circle
    /// * `inviter_pubkey` - Public key (hex) of the inviter
    ///
    /// [`process_gift_wrapped_invitation`]: Self::process_gift_wrapped_invitation
    pub async fn process_invitation(
        &self,
        wrapper_event_id: String,
        rumor_event_json: String,
        circle_name: String,
        inviter_pubkey: String,
    ) -> Result<InvitationFfi, String> {
        // Parse the event ID
        let event_id = nostr::EventId::from_hex(&wrapper_event_id)
            .map_err(|e| format!("Invalid event ID: {e}"))?;

        // Parse the rumor event from JSON
        let rumor: nostr::UnsignedEvent = serde_json::from_str(&rumor_event_json)
            .map_err(|e| format!("Invalid rumor event JSON: {e}"))?;

        let guard = self.inner.lock().await;
        guard
            .process_invitation(&event_id, &rumor, &circle_name, &inviter_pubkey)
            .map(InvitationFfi::from)
            .map_err(|e| e.to_string())
    }

    /// Gets all pending invitations.
    pub async fn get_pending_invitations(&self) -> Result<Vec<InvitationFfi>, String> {
        let guard = self.inner.lock().await;
        guard
            .get_pending_invitations()
            .map(|invitations| invitations.into_iter().map(InvitationFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Accepts an invitation to join a circle.
    pub async fn accept_invitation(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<CircleWithMembersFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let guard = self.inner.lock().await;
        guard
            .accept_invitation(&group_id)
            .map(|c| CircleWithMembersFfi::from(&c))
            .map_err(|e| e.to_string())
    }

    /// Declines an invitation to join a circle.
    pub async fn decline_invitation(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let guard = self.inner.lock().await;
        guard
            .decline_invitation(&group_id)
            .map_err(|e| e.to_string())
    }

    // ==================== Key Packages ====================

    /// Creates a key package for publishing.
    ///
    /// Returns the data needed to build and sign a kind 443 event.
    pub async fn create_key_package(
        &self,
        identity_pubkey: String,
        relays: Vec<String>,
    ) -> Result<KeyPackageBundleFfi, String> {
        let guard = self.inner.lock().await;
        guard
            .create_key_package(&identity_pubkey, &relays)
            .map(KeyPackageBundleFfi::from)
            .map_err(|e| e.to_string())
    }

    /// Finalizes a pending commit after publishing evolution events.
    ///
    /// Call this after successfully publishing the evolution event.
    pub async fn finalize_pending_commit(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let guard = self.inner.lock().await;
        guard
            .finalize_pending_commit(&group_id)
            .map_err(|e| e.to_string())
    }
}

impl std::fmt::Debug for CircleManagerFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleManagerFfi").finish()
    }
}

// ============================================================================
// Relay Management (FFI)
// ============================================================================

use haven_core::relay::{
    CircuitPurpose as CoreCircuitPurpose, PublishResult as CorePublishResult,
    RelayConnectionStatus as CoreRelayConnectionStatus, RelayManager as CoreRelayManager,
    RelayStatus as CoreRelayStatus, TorStatus as CoreTorStatus,
};

/// Tor bootstrap status (FFI-friendly).
#[derive(Debug, Clone)]
pub struct TorStatusFfi {
    /// Bootstrap progress percentage (0-100).
    pub progress: u8,
    /// Whether Tor is fully bootstrapped and ready.
    pub is_ready: bool,
    /// Current bootstrap phase description.
    pub phase: String,
}

impl From<CoreTorStatus> for TorStatusFfi {
    fn from(s: CoreTorStatus) -> Self {
        Self {
            progress: s.progress,
            is_ready: s.is_ready,
            phase: s.phase,
        }
    }
}

/// Relay connection status (FFI-friendly).
#[derive(Debug, Clone)]
pub struct RelayConnectionStatusFfi {
    /// The relay URL.
    pub url: String,
    /// Connection status: "connected", "disconnected", "connecting", or "failed".
    pub status: String,
    /// Last time the relay was seen (Unix timestamp), if known.
    pub last_seen: Option<i64>,
}

impl From<CoreRelayConnectionStatus> for RelayConnectionStatusFfi {
    fn from(s: CoreRelayConnectionStatus) -> Self {
        let status = match s.status {
            CoreRelayStatus::Connected => "connected",
            CoreRelayStatus::Disconnected => "disconnected",
            CoreRelayStatus::Connecting => "connecting",
            CoreRelayStatus::Failed { .. } => "failed",
        };
        Self {
            url: s.url,
            status: status.to_string(),
            last_seen: s.last_seen,
        }
    }
}

/// Result of publishing an event (FFI-friendly).
#[derive(Debug, Clone)]
pub struct PublishResultFfi {
    /// The event ID that was published (64-char hex).
    pub event_id: String,
    /// Relays that accepted the event.
    pub accepted_by: Vec<String>,
    /// Relays that rejected the event (URL, reason pairs).
    pub rejected_by: Vec<RelayRejectionFfi>,
    /// Relays that failed to respond.
    pub failed: Vec<String>,
    /// Whether at least one relay accepted the event.
    pub is_success: bool,
}

/// Relay rejection info (FFI-friendly).
#[derive(Debug, Clone)]
pub struct RelayRejectionFfi {
    /// Relay URL that rejected.
    pub url: String,
    /// Rejection reason.
    pub reason: String,
}

impl From<CorePublishResult> for PublishResultFfi {
    fn from(r: CorePublishResult) -> Self {
        let is_success = r.is_success();
        Self {
            event_id: r.event_id.to_hex(),
            accepted_by: r.accepted_by,
            rejected_by: r
                .rejected_by
                .into_iter()
                .map(|(url, reason)| RelayRejectionFfi { url, reason })
                .collect(),
            failed: r.failed,
            is_success,
        }
    }
}

/// Relay manager with mandatory Tor routing (FFI wrapper).
///
/// Handles all Nostr relay communication through the embedded Tor network
/// for privacy protection. User IPs are never exposed to relays.
///
/// # Security Model
///
/// - **Mandatory Tor**: All connections go through embedded Tor
/// - **Fail-closed**: No fallback to direct connections
/// - **Circuit isolation**: Different operations use separate circuits
/// - **WSS only**: Plaintext ws:// connections are rejected
///
/// # Usage
///
/// ```dart
/// final relayManager = await RelayManagerFfi.newInstance(dataDir);
///
/// // Wait for Tor bootstrap
/// while (!await relayManager.isReady()) {
///   final status = await relayManager.torStatus();
///   print('Tor bootstrap: ${status.progress}%');
///   await Future.delayed(Duration(milliseconds: 500));
/// }
///
/// // Publish an event
/// final result = await relayManager.publishEvent(
///   eventJson: signedEvent.toJson(),
///   relays: ['wss://relay.damus.io'],
///   isIdentityOperation: true,
/// );
/// ```
#[frb(opaque)]
pub struct RelayManagerFfi {
    inner: tokio::sync::Mutex<CoreRelayManager>,
}

impl RelayManagerFfi {
    /// Creates a new relay manager and begins Tor bootstrap.
    ///
    /// The manager will start bootstrapping the embedded Tor client.
    /// Use `is_ready()` or `tor_status()` to check bootstrap progress.
    pub async fn new_instance(data_dir: String) -> Result<Self, String> {
        let path = Path::new(&data_dir);
        CoreRelayManager::new(path)
            .await
            .map(|inner| Self {
                inner: tokio::sync::Mutex::new(inner),
            })
            .map_err(|e| e.to_string())
    }

    /// Returns the current Tor bootstrap status.
    pub async fn tor_status(&self) -> TorStatusFfi {
        let guard: tokio::sync::MutexGuard<'_, CoreRelayManager> = self.inner.lock().await;
        let status = guard.tor_status().await;
        TorStatusFfi::from(status)
    }

    /// Returns whether Tor is fully bootstrapped and ready.
    pub async fn is_ready(&self) -> bool {
        let guard: tokio::sync::MutexGuard<'_, CoreRelayManager> = self.inner.lock().await;
        guard.is_ready().await
    }

    /// Publishes a signed event to the specified relays.
    ///
    /// The event will be published through Tor to all specified relays.
    ///
    /// # Arguments
    ///
    /// * `event_json` - JSON-serialized signed Nostr event
    /// * `relays` - List of relay URLs (must be wss://)
    /// * `is_identity_operation` - If true, uses identity circuit; if false,
    ///   requires `nostr_group_id` for group-specific circuit
    /// * `nostr_group_id` - 32-byte group ID for circuit isolation (required
    ///   if `is_identity_operation` is false)
    pub async fn publish_event(
        &self,
        event_json: String,
        relays: Vec<String>,
        is_identity_operation: bool,
        nostr_group_id: Option<Vec<u8>>,
    ) -> Result<PublishResultFfi, String> {
        // Parse the event from JSON
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;

        // Determine circuit purpose
        let purpose = if is_identity_operation {
            CoreCircuitPurpose::Identity
        } else {
            let group_id = nostr_group_id.ok_or("nostr_group_id required for group operations")?;
            if group_id.len() != 32 {
                return Err(format!(
                    "Invalid nostr_group_id length: expected 32, got {}",
                    group_id.len()
                ));
            }
            let mut id = [0u8; 32];
            id.copy_from_slice(&group_id);
            CoreCircuitPurpose::GroupMessage { nostr_group_id: id }
        };

        let guard: tokio::sync::MutexGuard<'_, CoreRelayManager> = self.inner.lock().await;
        let result = guard
            .publish_event(&event, &relays, purpose)
            .await
            .map_err(|e| e.to_string())?;
        Ok(PublishResultFfi::from(result))
    }

    /// Gets the connection status of all relays.
    pub async fn get_relay_status(&self) -> Vec<RelayConnectionStatusFfi> {
        let guard: tokio::sync::MutexGuard<'_, CoreRelayManager> = self.inner.lock().await;
        let statuses = guard.get_relay_status().await;
        statuses
            .into_iter()
            .map(RelayConnectionStatusFfi::from)
            .collect()
    }

    /// Disconnects from all relays and shuts down Tor.
    pub async fn shutdown(&self) {
        let guard: tokio::sync::MutexGuard<'_, CoreRelayManager> = self.inner.lock().await;
        guard.shutdown().await;
    }

    // ==================== Event Fetching ====================

    /// Fetches a user's `KeyPackage` relay list (kind 10051).
    ///
    /// Returns the relay URLs where the user publishes their KeyPackages.
    /// Used to discover where to fetch a user's KeyPackage for inviting them.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub format)
    ///
    /// # Returns
    ///
    /// List of relay URLs, or empty if no relay list is published.
    pub async fn fetch_keypackage_relays(&self, pubkey: String) -> Result<Vec<String>, String> {
        let guard = self.inner.lock().await;
        guard
            .fetch_keypackage_relays(&pubkey)
            .await
            .map_err(|e| e.to_string())
    }

    /// Fetches a user's `KeyPackage` (kind 443).
    ///
    /// First fetches the user's KeyPackage relay list (kind 10051),
    /// then fetches the most recent KeyPackage from those relays.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub format)
    ///
    /// # Returns
    ///
    /// The KeyPackage event as JSON, or `None` if not found.
    /// Returns the event JSON so Flutter can cache and use it for circle creation.
    pub async fn fetch_keypackage(&self, pubkey: String) -> Result<Option<String>, String> {
        let guard = self.inner.lock().await;
        let event = guard
            .fetch_keypackage(&pubkey)
            .await
            .map_err(|e| e.to_string())?;

        Ok(event.map(|e| serde_json::to_string(&e).expect("Failed to serialize event")))
    }

    /// Fetches a user's `KeyPackage` with their relay list.
    ///
    /// Convenience method that returns both the KeyPackage and the relays
    /// where it was fetched, bundled for circle creation.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub format)
    ///
    /// # Returns
    ///
    /// A `MemberKeyPackageFfi` with the key package and inbox relays,
    /// or `None` if no KeyPackage was found.
    pub async fn fetch_member_keypackage(
        &self,
        pubkey: String,
    ) -> Result<Option<MemberKeyPackageFfi>, String> {
        let guard = self.inner.lock().await;

        // Fetch relay list first
        let relays = guard
            .fetch_keypackage_relays(&pubkey)
            .await
            .map_err(|e| e.to_string())?;

        // Fetch key package
        let event = guard
            .fetch_keypackage(&pubkey)
            .await
            .map_err(|e| e.to_string())?;

        Ok(event.map(|e| MemberKeyPackageFfi {
            key_package_json: serde_json::to_string(&e).expect("Failed to serialize event"),
            inbox_relays: relays,
        }))
    }
}

impl std::fmt::Debug for RelayManagerFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RelayManagerFfi").finish()
    }
}
