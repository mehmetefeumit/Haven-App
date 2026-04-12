//! API bridging layer that exposes haven-core functionality.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use flutter_rust_bridge::frb;
pub use haven_core::location::LocationPrecision;

/// Initializes the Rust runtime (logging, panic hooks).
///
/// Called automatically by `RustLib.init()` on the Dart side.
/// Sets up platform-native logging (Android logcat, iOS oslog)
/// so that `log::debug!` / `log::warn!` from Rust appear in
/// Flutter's debug console.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    // Suppress trace-level WebSocket frame logs from tungstenite/tokio-tungstenite.
    // These flood logcat and obscure Haven's own debug output.
    log::set_max_level(log::LevelFilter::Debug);
}
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
        let secret_bytes = zeroize::Zeroizing::new(secret_bytes);
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

/// Unsigned location event (FFI wrapper for inner event kind 9).
///
/// This is the inner event containing location data before encryption.
/// It is wrapped in a kind 445 group message for transmission.
#[derive(Debug, Clone)]
pub struct UnsignedLocationEventFfi {
    /// Event kind (9 for location data per MIP-03).
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

    /// Creates an unsigned location event (kind 9 per MIP-03).
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
// Platform Initialization
// ============================================================================

use std::sync::Mutex;

/// Guard for keyring store initialization. Only caches success so that transient
/// failures (e.g., iOS data protection not yet unlocked after reboot) can be
/// retried on the next call.
static KEYRING_INIT: Mutex<Option<()>> = Mutex::new(None);

/// Initializes the platform-specific keyring credential store.
///
/// Must be called **once** before any `CircleManagerFfi` operations. The keyring
/// store is used by MDK to securely store the `SQLCipher` database encryption key
/// in the platform's native credential store (Keychain, Keystore, etc.).
///
/// This function is idempotent: once initialization succeeds, subsequent calls
/// return `Ok(())` immediately. If initialization fails, the next call will
/// retry rather than returning a cached error.
///
/// # Errors
///
/// Returns an error string if the platform keyring store cannot be initialized
/// (e.g., on Android when the JNI context has not been provided).
pub fn init_keyring_store() -> Result<(), String> {
    let mut guard = KEYRING_INIT
        .lock()
        .map_err(|e| format!("Keyring lock poisoned: {e}"))?;
    if guard.is_some() {
        return Ok(());
    }
    platform_init_keyring().map_err(|e| format!("Keyring initialization failed: {e}"))?;
    *guard = Some(());
    Ok(())
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "linux",
    target_os = "windows",
    target_os = "android",
)))]
compile_error!("No keyring store implementation for this target OS");

/// Platform-specific keyring store initialization.
//
// `return` statements are needed inside cfg-gated branches because each
// branch is mutually exclusive — without them clippy fires `needless_return`
// only on whichever target is currently being compiled, which then varies
// across CI runners. Allow the lint at the function level to keep the
// branches symmetrical and platform-portable.
#[allow(clippy::needless_return)]
fn platform_init_keyring() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let store = apple_native_keyring_store::keychain::Store::new()
            .map_err(|e| format!("macOS keychain store: {e}"))?;
        keyring_core::set_default_store(store);
        return Ok(());
    }

    #[cfg(target_os = "ios")]
    {
        let store = apple_native_keyring_store::protected::Store::new()
            .map_err(|e| format!("iOS protected store: {e}"))?;
        keyring_core::set_default_store(store);
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        let store = zbus_secret_service_keyring_store::Store::new()
            .map_err(|e| format!("Linux secret service store: {e}"))?;
        keyring_core::set_default_store(store);
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    {
        let store = windows_native_keyring_store::Store::new()
            .map_err(|e| format!("Windows keyring store: {e}"))?;
        keyring_core::set_default_store(store);
        return Ok(());
    }

    #[cfg(target_os = "android")]
    {
        let store = android_native_keyring_store::Store::from_ndk_context()
            .map_err(|e| format!("Android keyring store: {e}"))?;
        keyring_core::set_default_store(store);
        return Ok(());
    }
}

// ============================================================================
// Circles DB Encryption Key Management
// ============================================================================

/// Keyring service identifier for circles.db encryption.
const CIRCLES_DB_SERVICE: &str = "com.haven.app";

/// Keyring key identifier for the circles.db encryption key.
const CIRCLES_DB_KEY_ID: &str = "circles.db.key";

/// Retrieves or creates the circles.db encryption key from the system keyring.
///
/// On first call, generates a cryptographically random 256-bit key using `OsRng`,
/// stores the raw bytes in the platform keyring, and returns the hex-encoded key.
/// Subsequent calls retrieve and hex-encode the stored key.
///
/// # Errors
///
/// Returns an error string if the keyring cannot be accessed or if key
/// generation fails.
fn get_or_create_circle_db_key() -> Result<zeroize::Zeroizing<String>, String> {
    use rand::RngCore;

    let entry = keyring_core::Entry::new(CIRCLES_DB_SERVICE, CIRCLES_DB_KEY_ID)
        .map_err(|e| format!("Failed to create keyring entry for circles.db: {e}"))?;

    match entry.get_secret() {
        Ok(secret_bytes) => {
            // Key exists — wrap in Zeroizing to ensure zeroing on drop, then hex-encode
            let secret_bytes = zeroize::Zeroizing::new(secret_bytes);
            Ok(zeroize::Zeroizing::new(hex::encode(&*secret_bytes)))
        }
        Err(keyring_core::Error::NoEntry) => {
            // Key doesn't exist — generate and store a new one
            let mut key_bytes = zeroize::Zeroizing::new([0u8; 32]);
            rand::rngs::OsRng.fill_bytes(key_bytes.as_mut());

            entry
                .set_secret(key_bytes.as_ref())
                .map_err(|e| format!("Failed to store circles.db key in keyring: {e}"))?;

            Ok(zeroize::Zeroizing::new(hex::encode(key_bytes.as_ref())))
        }
        Err(keyring_core::Error::NoStorageAccess(err)) => {
            Err(format!("Keyring not accessible for circles.db key: {err}"))
        }
        Err(e) => Err(format!("Failed to retrieve circles.db key: {e}")),
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
/// Contains the data needed to build a Nostr key package event.
/// Supports both addressable kind 30443 (preferred) and legacy kind 443.
#[derive(Debug, Clone)]
pub struct KeyPackageBundleFfi {
    /// Base64-encoded TLS-serialized key package (event content).
    pub content: String,
    /// Tags for the addressable kind 30443 event (preferred).
    pub tags_30443: Vec<Vec<String>>,
    /// Tags for the legacy kind 443 event.
    pub tags_443: Vec<Vec<String>>,
    /// Serialized `KeyPackageRef` for deletion by hash reference.
    pub hash_ref: Vec<u8>,
    /// NIP-33 `d` tag value for the addressable kind 30443 event.
    pub d_tag: String,
    /// Relay URLs where this key package will be published.
    pub relays: Vec<String>,
}

impl From<CoreKeyPackageBundle> for KeyPackageBundleFfi {
    fn from(b: CoreKeyPackageBundle) -> Self {
        Self {
            content: b.content,
            tags_30443: b.tags_30443,
            tags_443: b.tags_443,
            hash_ref: b.hash_ref,
            d_tag: b.d_tag,
            relays: b.relays,
        }
    }
}

/// A signed key package event ready for relay publishing (FFI-friendly).
///
/// Contains the signed key package Nostr event (kind 30443 addressable,
/// or legacy kind 443) and the relay URLs where it should be published.
#[derive(Debug, Clone)]
pub struct SignedKeyPackageEventFfi {
    /// The signed key package event as JSON string.
    pub event_json: String,
    /// Relay URLs where this event should be published.
    pub relays: Vec<String>,
}

/// A member's key package with their inbox relay list (FFI-friendly).
///
/// Used when adding members to a circle. The inbox relays are fetched
/// from the member's kind 10051 relay list and used for publishing
/// the gift-wrapped Welcome.
#[derive(Debug, Clone)]
pub struct MemberKeyPackageFfi {
    /// The key package event JSON (kind 30443 or legacy kind 443).
    pub key_package_json: String,
    /// Relay URLs where the Welcome should be sent (from kind 10051).
    pub inbox_relays: Vec<String>,
}

/// A gift-wrapped Welcome ready for publishing (FFI-friendly).
///
/// Contains the kind 1059 gift-wrapped event along with recipient
/// information needed for relay publishing.
#[derive(Clone)]
pub struct GiftWrappedWelcomeFfi {
    /// The recipient's Nostr public key (hex).
    pub recipient_pubkey: String,
    /// Relay URLs to publish this Welcome to (recipient's inbox relays).
    pub recipient_relays: Vec<String>,
    /// The gift-wrapped event JSON (kind 1059), ready to publish.
    pub event_json: String,
}

impl std::fmt::Debug for GiftWrappedWelcomeFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GiftWrappedWelcomeFfi")
            .field("recipient_pubkey", &"<redacted>")
            .field("recipient_relays", &self.recipient_relays)
            .field("event_json", &"<redacted>")
            .finish()
    }
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

/// Encrypted location event ready for relay publishing (FFI-friendly).
///
/// Contains the signed kind 445 event and routing metadata.
#[derive(Debug, Clone)]
pub struct EncryptedLocationFfi {
    /// JSON-serialized signed Nostr event (kind 445).
    pub event_json: String,
    /// Nostr group ID (32 bytes, for h-tag relay routing).
    pub nostr_group_id: Vec<u8>,
    /// Relay URLs to publish to.
    pub relays: Vec<String>,
}

/// Decrypted location from a peer (FFI-friendly).
///
/// Contains the sender identity and location data.
#[derive(Debug, Clone)]
pub struct DecryptedLocationFfi {
    /// Sender's Nostr public key (hex-encoded).
    pub sender_pubkey: String,
    /// Latitude (obfuscated to sender's precision).
    pub latitude: f64,
    /// Longitude (obfuscated to sender's precision).
    pub longitude: f64,
    /// Geohash of the location.
    pub geohash: String,
    /// When the location was recorded (Unix seconds).
    pub timestamp: i64,
    /// When this location expires (Unix seconds).
    pub expires_at: i64,
    /// Precision level ("Private", "Standard", or "Enhanced").
    pub precision: String,
    /// Sender's self-chosen display name (if provided).
    pub display_name: Option<String>,
    /// Sender's retention preference in seconds.
    ///
    /// Already clamped at the receiver to the configured maximum
    /// (30 days). A value of `0` is the sender-side "do not store"
    /// sentinel — the Flutter layer should treat it as a request to
    /// drop any persisted last-known row for this sender.
    pub retention_secs: u64,
}

/// A persisted last-known location for a circle member (FFI-friendly).
///
/// Mirrors `haven_core::circle::LastKnownLocation`. Returned from
/// `CircleManagerFfi::snapshot_last_known_for_circle` so the Flutter
/// layer can hydrate its in-memory cache on app start.
#[derive(Debug, Clone)]
pub struct LastKnownLocationFfi {
    /// Nostr group ID (32 bytes) of the circle.
    pub nostr_group_id: Vec<u8>,
    /// Sender's Nostr public key (hex-encoded).
    pub sender_pubkey: String,
    /// Latitude (obfuscated to sender's precision).
    pub latitude: f64,
    /// Longitude (obfuscated to sender's precision).
    pub longitude: f64,
    /// Geohash of the (obfuscated) location.
    pub geohash: String,
    /// Precision level ("Private", "Standard", or "Enhanced").
    pub precision: String,
    /// Display name carried in the encrypted location message, if any.
    pub display_name: Option<String>,
    /// When the location was captured (Unix seconds).
    pub timestamp: i64,
    /// When the inner freshness window expires (Unix seconds).
    pub expires_at: i64,
    /// Sender's retention request, already clamped to the receiver max.
    pub retention_secs: u64,
    /// Row must be deleted after this Unix-seconds moment.
    pub purge_after: i64,
    /// When this row was last written (Unix seconds, receiver clock).
    pub updated_at: i64,
}

/// Result of processing a kind 445 MLS group event (FFI-friendly).
///
/// Distinguishes between location messages and MLS group state changes
/// (commits, proposals) so the Flutter layer can refresh circle membership
/// when the group roster changes.
#[derive(Debug, Clone)]
pub struct DecryptResultFfi {
    /// The decrypted location, if this was an application message.
    /// `None` for group updates and unprocessable events.
    pub location: Option<DecryptedLocationFfi>,
    /// `true` when the event was an MLS commit or proposal that changed
    /// the group state (e.g., a new member joined). The Flutter layer
    /// should refresh the circle's member list when this is `true`.
    pub group_updated: bool,
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
    /// Canonical NIP-01 JSON of the evolution event, ready for relay publishing.
    pub evolution_event_json: String,
    /// Welcome events (kind 444) for newly added members (if any).
    pub welcome_events: Vec<UnsignedEventFfi>,
}

/// Result of leaving a circle (FFI-friendly).
///
/// Contains the leave event and optionally a demotion event (if the user
/// was an admin and had to self-demote first per MIP-03).
#[derive(Debug, Clone)]
pub struct LeaveCircleResultFfi {
    /// The demotion evolution event (if the user was an admin).
    /// Must be published to relays before the leave event.
    pub demote_event: Option<UpdateGroupResultFfi>,
    /// The leave evolution event.
    pub leave_event: UpdateGroupResultFfi,
}

/// Converts a core `UpdateGroupResult` into `UpdateGroupResultFfi`.
fn convert_update_result(
    result: haven_core::nostr::mls::types::UpdateGroupResult,
) -> Result<UpdateGroupResultFfi, String> {
    let evolution_event_json = serde_json::to_string(&result.evolution_event)
        .map_err(|e| format!("Failed to serialize evolution event: {e}"))?;

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
        evolution_event_json,
        welcome_events,
    })
}

// ==================== FFI input validation helpers ====================
//
// The actual validators live in `haven_core::validation` so they can be
// unit-tested from `cargo test -p haven-core` without the Flutter bridge.
use haven_core::validation::{
    normalize_pubkey_hex, parse_nostr_group_id, validate_precision_label, validate_pubkey_hex,
};

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
/// This type is `Send + Sync` via `Arc<CoreCircleManager>`. The underlying
/// `CircleManager` protects its SQLite connection with its own fine-grained
/// internal `Mutex`, so wrapping it in an outer mutex here would only
/// serialise every FFI call through a single global lock — a significant
/// throughput bottleneck under concurrent Dart→Rust traffic. Blocking
/// I/O work (SQLite, MDK) is dispatched to `tokio::task::spawn_blocking`
/// via [`run_blocking`] so it does not monopolise the async runtime's
/// worker threads. Pure-CPU `#[frb(sync)]` methods (e.g. constant
/// getters, relay list signing) bypass `run_blocking` and execute inline.
#[frb(opaque)]
pub struct CircleManagerFfi {
    inner: Arc<CoreCircleManager>,
}

// Compile-time assertion: the refactor above is only sound if the core
// manager is actually `Send + Sync`. If this ever stops compiling, the
// outer mutex must be reinstated (or the root cause fixed upstream).
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<CoreCircleManager>();
};

/// Dispatches a blocking closure onto tokio's dedicated blocking pool and
/// awaits its completion.
///
/// The closure owns an `Arc<CoreCircleManager>` clone, so it is free of
/// borrowing constraints and has the `'static` lifetime `spawn_blocking`
/// requires. A panic inside the closure is converted into a generic error
/// so raw panic payloads (which may contain redacted-but-unchecked
/// material) never reach the Dart layer.
#[inline]
async fn run_blocking<F, T>(f: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f).await.map_err(|e| {
        // Log only the failure category, never the panic payload — it may
        // contain key material or MLS group IDs via Debug representations.
        if e.is_panic() {
            log::error!("CircleManagerFfi blocking task panicked");
        } else {
            log::error!("CircleManagerFfi blocking task cancelled");
        }
        "Internal task failure".to_string()
    })?
}

impl CircleManagerFfi {
    /// Creates a new circle manager.
    ///
    /// Initializes both MLS storage and circle metadata database
    /// at the given data directory. Ensures the platform keyring store
    /// is initialized first (idempotent, safe to call multiple times).
    /// The circles.db database is encrypted with SQLCipher using a key
    /// stored in the platform keyring.
    pub fn new(data_dir: String) -> Result<Self, String> {
        init_keyring_store()?;
        let circle_db_key = get_or_create_circle_db_key()?;
        let path = Path::new(&data_dir);
        CoreCircleManager::new(path, Some(&circle_db_key))
            .map(|inner| Self {
                inner: Arc::new(inner),
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
        // Zeroize immediately so early-return paths don't leak secret bytes.
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
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

        // `CircleManager::create_circle` is genuinely async (giftwrap
        // construction awaits), so it stays on the current tokio worker.
        // The inner SQLite writes are still protected by the core's own
        // fine-grained mutex.
        let result = self
            .inner
            .create_circle(&keys, member_key_packages, &config)
            .await
            .map_err(|e| e.to_string())?;

        // Convert gift-wrapped welcome events to FFI
        let welcome_events: Vec<GiftWrappedWelcomeFfi> = result
            .welcome_events
            .into_iter()
            .map(|w| {
                let event_json = serde_json::to_string(&w.event)
                    .map_err(|e| format!("Failed to serialize welcome event: {e}"))?;
                Ok(GiftWrappedWelcomeFfi {
                    recipient_pubkey: w.recipient_pubkey,
                    recipient_relays: w.recipient_relays,
                    event_json,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;

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
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .get_circle(&group_id)
                .map(|opt| opt.map(|c| CircleWithMembersFfi::from(&c)))
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Gets all circles.
    pub async fn get_circles(&self) -> Result<Vec<CircleWithMembersFfi>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_circles()
                .map(|circles| circles.iter().map(CircleWithMembersFfi::from).collect())
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Gets visible circles (excludes declined invitations).
    pub async fn get_visible_circles(&self) -> Result<Vec<CircleWithMembersFfi>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_visible_circles()
                .map(|circles| circles.iter().map(CircleWithMembersFfi::from).collect())
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Leaves a circle.
    ///
    /// If the user is an admin, they are automatically self-demoted first
    /// (MIP-03 requirement). Returns all evolution events to publish.
    pub async fn leave_circle(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<LeaveCircleResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner.leave_circle(&group_id).map_err(|e| e.to_string())
        })
        .await?;

        let demote_event = match result.demote_result {
            Some(r) => Some(convert_update_result(r)?),
            None => None,
        };
        let leave_event = convert_update_result(result.leave_result)?;

        Ok(LeaveCircleResultFfi {
            demote_event,
            leave_event,
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
        // Parse key packages from JSON (pure CPU work, off the blocking pool).
        let key_packages: Vec<nostr::Event> = key_packages_json
            .iter()
            .map(|json| {
                serde_json::from_str(json).map_err(|e| format!("Invalid key package JSON: {e}"))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .add_members(&group_id, &key_packages)
                .map_err(|e| e.to_string())
        })
        .await?;

        convert_update_result(result)
    }

    /// Removes members from a circle.
    ///
    /// Returns the update result with evolution events.
    pub async fn remove_members(
        &self,
        mls_group_id: Vec<u8>,
        member_pubkeys: Vec<String>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .remove_members(&group_id, &member_pubkeys)
                .map_err(|e| e.to_string())
        })
        .await?;

        convert_update_result(result)
    }

    /// Gets members of a circle with resolved contact info.
    pub async fn get_members(&self, mls_group_id: Vec<u8>) -> Result<Vec<CircleMemberFfi>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .get_members(&group_id)
                .map(|members| members.iter().map(CircleMemberFfi::from).collect())
                .map_err(|e| e.to_string())
        })
        .await
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
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .set_contact(
                    &pubkey,
                    display_name.as_deref(),
                    avatar_path.as_deref(),
                    notes.as_deref(),
                )
                .map(ContactFfi::from)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Gets a contact by pubkey.
    pub async fn get_contact(&self, pubkey: String) -> Result<Option<ContactFfi>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_contact(&pubkey)
                .map(|opt| opt.map(ContactFfi::from))
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Gets all contacts.
    pub async fn get_all_contacts(&self) -> Result<Vec<ContactFfi>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_all_contacts()
                .map(|contacts| contacts.into_iter().map(ContactFfi::from).collect())
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Deletes a contact.
    pub async fn delete_contact(&self, pubkey: String) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || inner.delete_contact(&pubkey).map_err(|e| e.to_string())).await
    }

    // ==================== Invitation Handling ====================

    /// Processes a gift-wrapped Welcome event (kind 1059).
    ///
    /// This is the high-level API for processing incoming invitations.
    /// It unwraps the gift-wrapped event, extracts the sender info,
    /// and processes the invitation. Circle name and relays are
    /// extracted from the Welcome's embedded group data.
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The recipient's identity secret bytes (32 bytes)
    /// * `gift_wrap_event_json` - The kind 1059 gift-wrapped event JSON
    ///
    /// # Returns
    ///
    /// The pending invitation, which can be accepted or declined.
    pub async fn process_gift_wrapped_invitation(
        &self,
        identity_secret_bytes: Vec<u8>,
        gift_wrap_event_json: String,
    ) -> Result<InvitationFfi, String> {
        // Zeroize immediately so early-return paths don't leak secret bytes.
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        // Parse the gift-wrapped event
        let gift_wrap_event: nostr::Event = serde_json::from_str(&gift_wrap_event_json)
            .map_err(|e| format!("Invalid gift wrap event JSON: {e}"))?;

        // Genuinely async — NIP-59 giftwrap unwrap awaits internally.
        self.inner
            .process_gift_wrapped_invitation(&keys, &gift_wrap_event)
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
    /// * `inviter_pubkey` - Public key (hex) of the inviter
    ///
    /// [`process_gift_wrapped_invitation`]: Self::process_gift_wrapped_invitation
    pub async fn process_invitation(
        &self,
        wrapper_event_id: String,
        rumor_event_json: String,
        inviter_pubkey: String,
    ) -> Result<InvitationFfi, String> {
        // Parse the event ID
        let event_id = nostr::EventId::from_hex(&wrapper_event_id)
            .map_err(|e| format!("Invalid event ID: {e}"))?;

        // Parse the rumor event from JSON
        let rumor: nostr::UnsignedEvent = serde_json::from_str(&rumor_event_json)
            .map_err(|e| format!("Invalid rumor event JSON: {e}"))?;

        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .process_invitation(&event_id, &rumor, &inviter_pubkey)
                .map(InvitationFfi::from)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Gets all pending invitations.
    pub async fn get_pending_invitations(&self) -> Result<Vec<InvitationFfi>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_pending_invitations()
                .map(|invitations| invitations.into_iter().map(InvitationFfi::from).collect())
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Accepts an invitation to join a circle.
    pub async fn accept_invitation(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<CircleWithMembersFfi, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .accept_invitation(&group_id)
                .map(|c| CircleWithMembersFfi::from(&c))
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Declines an invitation to join a circle.
    pub async fn decline_invitation(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .decline_invitation(&group_id)
                .map_err(|e| e.to_string())
        })
        .await
    }

    // ==================== Key Packages ====================

    /// Creates a key package for publishing.
    ///
    /// Returns the data needed to build and sign a key package event
    /// (kind 30443 addressable or legacy kind 443).
    pub async fn create_key_package(
        &self,
        identity_pubkey: String,
        relays: Vec<String>,
    ) -> Result<KeyPackageBundleFfi, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .create_key_package(&identity_pubkey, &relays)
                .map(KeyPackageBundleFfi::from)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Creates and signs a key package event (kind 30443) for relay publishing.
    ///
    /// Generates MLS key material, builds the Nostr event, and signs it
    /// with the identity key. Returns the signed event ready for publishing.
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The user's identity secret bytes (32 bytes)
    /// * `relays` - Relay URLs where this key package should be published
    pub async fn sign_key_package_event(
        &self,
        identity_secret_bytes: Vec<u8>,
        relays: Vec<String>,
    ) -> Result<SignedKeyPackageEventFfi, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);
        let pubkey_hex = keys.public_key().to_hex();

        // Generate MLS key package on the blocking pool (touches SQLite).
        let bundle = {
            let inner = self.inner.clone();
            run_blocking(move || {
                inner
                    .create_key_package(&pubkey_hex, &relays)
                    .map_err(|e| e.to_string())
            })
            .await?
        };
        // Bundle is owned now; signing below is pure CPU work.

        // Parse tags from Vec<Vec<String>> into nostr::Tag.
        // Use kind 30443 (addressable) tags — the preferred format per MIP-00.
        let tags: Vec<nostr::Tag> = bundle
            .tags_30443
            .into_iter()
            .map(|tag_vec| {
                nostr::Tag::parse(&tag_vec)
                    .map_err(|e| format!("Failed to parse key package tag: {e}"))
            })
            .collect::<Result<Vec<_>, String>>()?;

        // Build and sign addressable kind 30443 event (replaces legacy kind 443).
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(30443), bundle.content)
            .tags(tags)
            .sign_with_keys(&keys)
            .map_err(|e| format!("Failed to sign key package event: {e}"))?;

        let event_json =
            serde_json::to_string(&event).map_err(|e| format!("Failed to serialize event: {e}"))?;

        Ok(SignedKeyPackageEventFfi {
            event_json,
            relays: bundle.relays,
        })
    }

    /// Signs a relay list event (kind 10051) for key package discovery.
    ///
    /// Builds and signs a replaceable event listing the relays where the user's
    /// key packages are published. Other clients use this to discover where to
    /// fetch key packages for invitation.
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The user's identity secret bytes (32 bytes)
    /// * `relays` - Relay URLs to advertise
    #[frb(sync)]
    pub fn sign_relay_list_event(
        &self,
        identity_secret_bytes: Vec<u8>,
        relays: Vec<String>,
    ) -> Result<String, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        let tags: Vec<nostr::Tag> = relays
            .iter()
            .map(|url| {
                nostr::Tag::parse(["relay", url.as_str()])
                    .map_err(|e| format!("Failed to parse relay tag: {e}"))
            })
            .collect::<Result<Vec<_>, String>>()?;

        let event = nostr::EventBuilder::new(nostr::Kind::MlsKeyPackageRelays, "")
            .tags(tags)
            .sign_with_keys(&keys)
            .map_err(|e| format!("Failed to sign relay list event: {e}"))?;

        serde_json::to_string(&event).map_err(|e| format!("Failed to serialize event: {e}"))
    }

    /// Signs a NIP-09 event deletion event.
    ///
    /// Creates a kind 5 deletion event referencing the given event IDs,
    /// signed with the provided identity key. Used to delete consumed
    /// `KeyPackage` events from relays after rotation.
    #[frb(sync)]
    pub fn sign_deletion_event(
        &self,
        identity_secret_bytes: Vec<u8>,
        event_ids: Vec<String>,
    ) -> Result<String, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        if event_ids.is_empty() {
            return Err("No event IDs provided for deletion".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        let ids: Vec<nostr::EventId> = event_ids
            .iter()
            .map(|id| {
                nostr::EventId::from_hex(id).map_err(|e| format!("Invalid event ID '{id}': {e}"))
            })
            .collect::<Result<Vec<_>, String>>()?;

        let deletion = nostr::nips::nip09::EventDeletionRequest::new().ids(ids);
        let event = nostr::EventBuilder::delete(deletion)
            .sign_with_keys(&keys)
            .map_err(|e| format!("Failed to sign deletion event: {e}"))?;

        serde_json::to_string(&event)
            .map_err(|e| format!("Failed to serialize deletion event: {e}"))
    }

    /// Performs a self-update on the user's leaf node in a group.
    ///
    /// Rotates the user's MLS key material to restore forward secrecy
    /// after joining a group (MIP-02 requirement). Returns the evolution
    /// event to publish and creates a pending commit that must be merged
    /// (on publish success) or cleared (on publish failure).
    pub async fn self_update(&self, mls_group_id: Vec<u8>) -> Result<UpdateGroupResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner.self_update(&group_id).map_err(|e| e.to_string())
        })
        .await?;

        convert_update_result(result)
    }

    /// Returns groups where the user's leaf node key material needs rotation.
    ///
    /// Groups are returned if the self-update is either required (post-join,
    /// not yet completed) or overdue (last rotation older than `threshold_secs`).
    /// Callers should iterate the result and call [`self_update`] for each.
    pub async fn groups_needing_self_update(
        &self,
        threshold_secs: u64,
    ) -> Result<Vec<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .groups_needing_self_update(threshold_secs)
                .map(|ids| ids.into_iter().map(|id| id.to_vec()).collect())
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Finalizes a pending commit after publishing evolution events.
    ///
    /// Call this after successfully publishing the evolution event.
    pub async fn finalize_pending_commit(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .finalize_pending_commit(&group_id)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Clears a pending commit, rolling back the MLS group state.
    ///
    /// Call this when a relay publish fails after an operation that creates
    /// a pending commit. This prevents the group from being permanently
    /// blocked by a dangling pending commit.
    pub async fn clear_pending_commit(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .clear_pending_commit(&group_id)
                .map_err(|e| e.to_string())
        })
        .await
    }

    // ==================== Location Sharing ====================

    /// Encrypts a location for a circle.
    ///
    /// Creates an MLS-encrypted kind 445 event containing the location data.
    /// The returned event is ready to publish to the circle's relays.
    ///
    /// # Concurrency
    ///
    /// MDK's `create_message` performs a non-atomic read-modify-write on the
    /// MLS group state. Two concurrent calls for the **same** group can race
    /// on the epoch counter, causing one message to be rejected by all
    /// recipients. Callers **must not** invoke this method concurrently for
    /// the same `mls_group_id`. The Dart-side `locationPublisherProvider`
    /// satisfies this constraint by publishing one group at a time per
    /// publish cycle. If this ever changes, add a per-group `Mutex` here.
    ///
    /// # Arguments
    ///
    /// * `mls_group_id` - The circle's MLS group ID
    /// * `sender_pubkey_hex` - The sender's Nostr public key (hex)
    /// * `latitude` - GPS latitude
    /// * `longitude` - GPS longitude
    pub async fn encrypt_location(
        &self,
        mls_group_id: Vec<u8>,
        sender_pubkey_hex: String,
        latitude: f64,
        longitude: f64,
        display_name: Option<String>,
        retention_secs: u64,
    ) -> Result<EncryptedLocationFfi, String> {
        let sender_pubkey = nostr::PublicKey::parse(&sender_pubkey_hex)
            .map_err(|e| format!("Invalid sender pubkey: {e}"))?;
        // `with_retention_secs` clamps to the receiver-side ceiling
        // (`LOCATION_RECEIVER_MAX_RETENTION_SECS`).
        let location = haven_core::location::LocationMessage::new(latitude, longitude)
            .with_display_name(display_name)
            .with_retention_secs(retention_secs);

        let inner = self.inner.clone();
        let (event, nostr_group_id, relays) = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .encrypt_location(&group_id, &sender_pubkey, &location)
                .map_err(|e| e.to_string())
        })
        .await?;

        let event_json =
            serde_json::to_string(&event).map_err(|e| format!("Failed to serialize event: {e}"))?;

        Ok(EncryptedLocationFfi {
            event_json,
            nostr_group_id: nostr_group_id.to_vec(),
            relays,
        })
    }

    /// Decrypts a received location event.
    ///
    /// Processes a kind 445 event through MLS decryption.
    ///
    /// # Concurrency
    ///
    /// Same constraint as [`encrypt_location`]: concurrent calls for the
    /// same group can race on MLS epoch state. The Dart-side
    /// `fetchMemberLocations` processes events sequentially per circle.
    ///
    /// Returns a [`DecryptResultFfi`] that distinguishes between:
    /// - **Location messages**: `location` is `Some`, `group_updated` is `false`
    /// - **Group updates** (commits/proposals): `location` is `None`,
    ///   `group_updated` is `true` — the caller should refresh the circle's
    ///   member list
    /// - **Unprocessable / previously-failed**: `None`
    ///
    /// # Arguments
    ///
    /// * `event_json` - JSON-serialized kind 445 event
    pub async fn decrypt_location(
        &self,
        event_json: String,
    ) -> Result<Option<DecryptResultFfi>, String> {
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;

        let inner = self.inner.clone();
        let result =
            run_blocking(move || inner.decrypt_location(&event).map_err(|e| e.to_string())).await?;

        match result {
            haven_core::nostr::mls::types::LocationMessageResult::Location {
                sender_pubkey,
                content,
                ..
            } => {
                let location: haven_core::location::LocationMessage =
                    serde_json::from_str(&content)
                        .map_err(|e| format!("Failed to parse location: {e}"))?;
                // Defensively clamp the sender's requested retention to the
                // receiver-side ceiling so the Flutter layer never sees an
                // unbounded value.
                let retention_secs = location
                    .retention_secs
                    .min(haven_core::location::LOCATION_RECEIVER_MAX_RETENTION_SECS);
                // Normalize to lowercase so Dart-side self-compare against
                // the cached own pubkey is case-insensitive by construction.
                let sender_pubkey = normalize_pubkey_hex(&sender_pubkey);
                Ok(Some(DecryptResultFfi {
                    location: Some(DecryptedLocationFfi {
                        sender_pubkey,
                        latitude: location.latitude,
                        longitude: location.longitude,
                        geohash: location.geohash,
                        timestamp: location.timestamp.timestamp(),
                        expires_at: location.expires_at.timestamp(),
                        precision: location.precision.label().to_string(),
                        display_name: haven_core::location::types::sanitize_display_name(
                            location.display_name,
                        ),
                        retention_secs,
                    }),
                    group_updated: false,
                }))
            }
            haven_core::nostr::mls::types::LocationMessageResult::GroupUpdate { .. } => {
                Ok(Some(DecryptResultFfi {
                    location: None,
                    group_updated: true,
                }))
            }
            haven_core::nostr::mls::types::LocationMessageResult::Unprocessable { .. }
            | haven_core::nostr::mls::types::LocationMessageResult::PreviouslyFailed => Ok(None),
        }
    }

    // ==================== Last-Known Location Cache ====================

    /// Persists a last-known location row.
    ///
    /// Input is validated at the FFI boundary; the core manager is the
    /// authoritative enforcement point for retention clamping and
    /// `purge_after` derivation. The `purge_after` and `retention_secs`
    /// values supplied by the caller are advisory only — the core
    /// recomputes both using the receiver-side ceiling.
    pub async fn upsert_last_known_location(
        &self,
        location: LastKnownLocationFfi,
    ) -> Result<(), String> {
        let ngid = parse_nostr_group_id(&location.nostr_group_id)?;
        validate_pubkey_hex(&location.sender_pubkey, "sender_pubkey")?;
        validate_precision_label(&location.precision)?;
        let sender_pubkey = normalize_pubkey_hex(&location.sender_pubkey);

        let core = haven_core::circle::LastKnownLocation {
            nostr_group_id: ngid,
            sender_pubkey,
            latitude: location.latitude,
            longitude: location.longitude,
            geohash: location.geohash,
            precision: location.precision,
            display_name: location.display_name,
            timestamp: location.timestamp,
            expires_at: location.expires_at,
            // Core re-clamps this; caller value is advisory only.
            retention_secs: location.retention_secs,
            // Core re-derives this from timestamp + clamped retention;
            // caller value is ignored.
            purge_after: location.purge_after,
            updated_at: location.updated_at,
        };

        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .upsert_last_known_location(&core)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Returns all non-purged last-known locations for a circle.
    pub async fn snapshot_last_known_for_circle(
        &self,
        nostr_group_id: Vec<u8>,
        now_unix_secs: i64,
    ) -> Result<Vec<LastKnownLocationFfi>, String> {
        let ngid = parse_nostr_group_id(&nostr_group_id)?;

        let inner = self.inner.clone();
        let rows = run_blocking(move || {
            inner
                .snapshot_last_known_for_circle(&ngid, now_unix_secs)
                .map_err(|e| e.to_string())
        })
        .await?;

        Ok(rows
            .into_iter()
            .map(|loc| LastKnownLocationFfi {
                nostr_group_id: loc.nostr_group_id.to_vec(),
                sender_pubkey: loc.sender_pubkey,
                latitude: loc.latitude,
                longitude: loc.longitude,
                geohash: loc.geohash,
                precision: loc.precision,
                display_name: loc.display_name,
                timestamp: loc.timestamp,
                expires_at: loc.expires_at,
                retention_secs: loc.retention_secs,
                purge_after: loc.purge_after,
                updated_at: loc.updated_at,
            })
            .collect())
    }

    /// Removes the last-known location for a single sender in a circle.
    ///
    /// Called when a sender publishes `retention_secs = 0` or when a member
    /// is removed from the circle.
    pub async fn remove_last_known_member(
        &self,
        nostr_group_id: Vec<u8>,
        sender_pubkey: String,
    ) -> Result<(), String> {
        let ngid = parse_nostr_group_id(&nostr_group_id)?;
        validate_pubkey_hex(&sender_pubkey, "sender_pubkey")?;
        let sender_pubkey = normalize_pubkey_hex(&sender_pubkey);

        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .remove_last_known_member(&ngid, &sender_pubkey)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Removes every last-known location row for a sender across all circles.
    ///
    /// Used by the "Clear my location from others" flow so the caller does
    /// not have to iterate circles (including hidden ones) on the Dart side.
    /// Returns the number of rows removed.
    pub async fn remove_last_known_for_sender(&self, sender_pubkey: String) -> Result<u32, String> {
        validate_pubkey_hex(&sender_pubkey, "sender_pubkey")?;
        let sender_pubkey = normalize_pubkey_hex(&sender_pubkey);

        let inner = self.inner.clone();
        let removed = run_blocking(move || {
            inner
                .remove_last_known_for_sender(&sender_pubkey)
                .map_err(|e| e.to_string())
        })
        .await?;
        Ok(u32::try_from(removed).unwrap_or(u32::MAX))
    }

    /// Removes every last-known location row for a circle.
    ///
    /// Called when the user leaves or deletes a circle.
    pub async fn remove_last_known_circle(&self, nostr_group_id: Vec<u8>) -> Result<(), String> {
        let ngid = parse_nostr_group_id(&nostr_group_id)?;

        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .remove_last_known_circle(&ngid)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Wipes every last-known location row.
    ///
    /// Called from the identity-deletion path so no stale location data
    /// survives a full account wipe.
    pub async fn wipe_all_last_known_locations(&self) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .wipe_all_last_known_locations()
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Deletes every row whose `purge_after < now_unix_secs`.
    ///
    /// Returns the number of rows removed.
    pub async fn prune_expired_last_known(&self, now_unix_secs: i64) -> Result<u32, String> {
        let inner = self.inner.clone();
        let removed = run_blocking(move || {
            inner
                .prune_expired_last_known(now_unix_secs)
                .map_err(|e| e.to_string())
        })
        .await?;
        // Reasonable: never expect billions of rows.
        Ok(u32::try_from(removed).unwrap_or(u32::MAX))
    }

    /// Receiver-side ceiling for sender-controlled retention (seconds).
    ///
    /// Exposed so the Flutter layer can mirror the same clamp without
    /// hard-coding the value.
    #[frb(sync)]
    pub fn location_receiver_max_retention_secs(&self) -> u64 {
        haven_core::location::LOCATION_RECEIVER_MAX_RETENTION_SECS
    }

    /// Default sender retention preference (seconds).
    #[frb(sync)]
    pub fn default_sender_retention_secs(&self) -> u64 {
        haven_core::location::DEFAULT_SENDER_RETENTION_SECS
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
    PublishResult as CorePublishResult, RelayConnectionStatus as CoreRelayConnectionStatus,
    RelayEventCheck as CoreRelayEventCheck, RelayManager as CoreRelayManager,
    RelayStatus as CoreRelayStatus,
};

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

/// Result of checking whether events exist on a specific relay (FFI-friendly).
#[derive(Debug, Clone)]
pub struct RelayEventCheckFfi {
    /// The relay URL that was checked.
    pub relay_url: String,
    /// Whether at least one matching event was found.
    pub found: bool,
    /// Number of matching events found.
    pub event_count: u32,
    /// Newest event timestamp (Unix seconds), if any.
    pub newest_timestamp: Option<i64>,
}

impl From<CoreRelayEventCheck> for RelayEventCheckFfi {
    fn from(c: CoreRelayEventCheck) -> Self {
        Self {
            relay_url: c.relay_url,
            found: c.found,
            event_count: c.event_count as u32,
            newest_timestamp: c.newest_timestamp,
        }
    }
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

/// Relay manager (FFI wrapper).
///
/// Handles all Nostr relay communication via direct WSS connections.
///
/// # Security Model
///
/// - **WSS only**: Plaintext ws:// connections are rejected
///
/// # Usage
///
/// ```dart
/// final relayManager = await RelayManagerFfi.newInstance();
///
/// // Publish an event
/// final result = await relayManager.publishEvent(
///   eventJson: signedEvent.toJson(),
///   relays: ['wss://relay.damus.io'],
/// );
/// ```
#[frb(opaque)]
pub struct RelayManagerFfi {
    inner: CoreRelayManager,
}

impl RelayManagerFfi {
    /// Creates a new relay manager.
    pub async fn new_instance() -> Result<Self, String> {
        Ok(Self {
            inner: CoreRelayManager::new(),
        })
    }

    /// Publishes a signed event to the specified relays.
    ///
    /// # Arguments
    ///
    /// * `event_json` - JSON-serialized signed Nostr event
    /// * `relays` - List of relay URLs (must be wss://)
    pub async fn publish_event(
        &self,
        event_json: String,
        relays: Vec<String>,
    ) -> Result<PublishResultFfi, String> {
        // Parse the event from JSON
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;

        let result = self
            .inner
            .publish_event(&event, &relays)
            .await
            .map_err(|e| e.to_string())?;
        Ok(PublishResultFfi::from(result))
    }

    /// Publishes an event in the background without waiting for relay acknowledgment.
    ///
    /// Spawns a background task. Suitable for location updates and key package
    /// re-publishes where periodic timers ensure eventual delivery.
    pub fn publish_event_fire_and_forget(
        &self,
        event_json: String,
        relays: Vec<String>,
    ) -> Result<(), String> {
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;

        self.inner
            .publish_event_background(event, &relays)
            .map_err(|e| e.to_string())
    }

    /// Gets the connection status of all relays.
    pub async fn get_relay_status(&self) -> Vec<RelayConnectionStatusFfi> {
        let statuses = self.inner.get_relay_status().await;
        statuses
            .into_iter()
            .map(RelayConnectionStatusFfi::from)
            .collect()
    }

    /// Disconnects from all relays.
    pub async fn shutdown(&self) {
        self.inner.shutdown().await;
    }

    // ==================== Event Checking ====================

    /// Checks whether events of a given kind by an author exist on a relay.
    ///
    /// Queries a single relay for events matching the given kind and author.
    /// Used to verify that KeyPackage (443) and relay list (10051) events
    /// are published.
    pub async fn check_event_on_relay(
        &self,
        relay_url: String,
        author_pubkey: String,
        event_kind: u16,
    ) -> Result<RelayEventCheckFfi, String> {
        let pk = nostr::PublicKey::parse(&author_pubkey)
            .map_err(|e| format!("Invalid author pubkey: {e}"))?;

        let filter = nostr::Filter::new()
            .kind(nostr::Kind::Custom(event_kind))
            .author(pk)
            .limit(5);

        let result = self
            .inner
            .check_event_on_relay(&relay_url, filter)
            .await
            .map_err(|e| e.to_string())?;

        Ok(RelayEventCheckFfi::from(result))
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
        self.inner
            .fetch_keypackage_relays(&pubkey)
            .await
            .map_err(|e| e.to_string())
    }

    /// Fetches a user's key package (kind 30443 or legacy kind 443).
    ///
    /// First fetches the user's key package relay list (kind 10051),
    /// then fetches the most recent key package from those relays.
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
        let event = self
            .inner
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
        // Fetch relay list first
        let relays = self
            .inner
            .fetch_keypackage_relays(&pubkey)
            .await
            .map_err(|e| e.to_string())?;

        // Fetch key package, reusing the relay list we already have
        let event = self
            .inner
            .fetch_keypackage_from_relays(&pubkey, &relays)
            .await
            .map_err(|e| e.to_string())?;

        Ok(event.map(|e| MemberKeyPackageFfi {
            key_package_json: serde_json::to_string(&e).expect("Failed to serialize event"),
            inbox_relays: relays,
        }))
    }

    /// Fetches gift-wrapped events (kind 1059) addressed to a recipient.
    ///
    /// Queries the given relays for NIP-59 gift wrap events tagged with the
    /// recipient's public key. An optional `since` timestamp restricts results
    /// to events created after that point.
    ///
    /// # Arguments
    ///
    /// * `recipient_pubkey` - The recipient's public key (hex or npub format)
    /// * `relays` - Relay URLs to query
    /// * `since` - Optional Unix timestamp (seconds); only events after this time are returned
    ///
    /// # Returns
    ///
    /// A list of gift-wrap events serialized as JSON strings.
    pub async fn fetch_gift_wraps(
        &self,
        recipient_pubkey: String,
        relays: Vec<String>,
        since: Option<i64>,
    ) -> Result<Vec<String>, String> {
        let pk = nostr::PublicKey::parse(&recipient_pubkey)
            .map_err(|e| format!("Invalid recipient pubkey: {e}"))?;

        let mut filter = nostr::Filter::new()
            .kind(nostr::Kind::GiftWrap)
            .pubkey(pk)
            .limit(100);

        if let Some(ts) = since {
            let secs = u64::try_from(ts).map_err(|_| "since timestamp must be non-negative")?;
            filter = filter.since(nostr::Timestamp::from(secs));
        }

        let events = self
            .inner
            .fetch_events(filter, &relays, None)
            .await
            .map_err(|e| e.to_string())?;

        events
            .into_iter()
            .map(|e| {
                serde_json::to_string(&e).map_err(|err| format!("Failed to serialize event: {err}"))
            })
            .collect::<Result<Vec<_>, _>>()
    }

    /// Fetches MLS group messages (kind 445) from relays.
    ///
    /// Queries relays for encrypted group messages using the h-tag
    /// for routing.
    ///
    /// # Arguments
    ///
    /// * `nostr_group_id` - 32-byte Nostr group ID (h-tag value)
    /// * `relays` - Relay URLs to query
    /// * `since` - Optional Unix timestamp (seconds); only events after this time
    /// * `limit` - Maximum number of events to return
    pub async fn fetch_group_messages(
        &self,
        nostr_group_id: Vec<u8>,
        relays: Vec<String>,
        since: Option<i64>,
        limit: Option<u32>,
    ) -> Result<Vec<String>, String> {
        if nostr_group_id.len() != 32 {
            return Err(format!(
                "Invalid nostr_group_id length: expected 32, got {}",
                nostr_group_id.len()
            ));
        }

        let group_id_hex: String = nostr_group_id.iter().map(|b| format!("{b:02x}")).collect();

        let mut filter = nostr::Filter::new()
            .kind(nostr::Kind::Custom(445))
            .custom_tag(
                nostr::SingleLetterTag::lowercase(nostr::Alphabet::H),
                group_id_hex,
            );

        if let Some(ts) = since {
            let secs = u64::try_from(ts).map_err(|_| "since timestamp must be non-negative")?;
            filter = filter.since(nostr::Timestamp::from(secs));
        }

        if let Some(lim) = limit {
            filter = filter.limit(lim as usize);
        }

        let events = self
            .inner
            .fetch_events(filter, &relays, None)
            .await
            .map_err(|e| e.to_string())?;

        events
            .into_iter()
            .map(|e| {
                serde_json::to_string(&e).map_err(|err| format!("Failed to serialize event: {err}"))
            })
            .collect::<Result<Vec<_>, _>>()
    }
}

impl std::fmt::Debug for RelayManagerFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RelayManagerFfi").finish()
    }
}

/// Tests for the platform keyring initialization logic.
///
/// **Note on test isolation**: `KEYRING_INIT` is a process-global static.
/// Because `cargo test` runs tests in the same process by default, tests that
/// mutate this static can interfere with each other. Run with
/// `cargo test -- --test-threads=1` for deterministic ordering if needed.
///
/// Tests marked `#[ignore]` require a live keyring backend (D-Bus Secret Service
/// on Linux, Keychain on macOS, Credential Manager on Windows). They will fail in
/// headless CI environments (Docker, SSH without a session bus).
#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies that `init_keyring_store()` succeeds when a keyring backend
    /// is available.
    #[test]
    #[ignore = "requires a running keyring backend (D-Bus Secret Service on Linux)"]
    fn init_keyring_store_succeeds() {
        let result = init_keyring_store();
        assert!(result.is_ok(), "init_keyring_store failed: {result:?}");
    }

    /// Verifies idempotency: calling `init_keyring_store()` twice must both
    /// return `Ok(())`. The second call should hit the `guard.is_some()` fast
    /// path without re-initializing the platform store.
    #[test]
    #[ignore = "requires a running keyring backend (D-Bus Secret Service on Linux)"]
    fn init_keyring_store_is_idempotent() {
        let first = init_keyring_store();
        assert!(first.is_ok(), "first init failed: {first:?}");

        let second = init_keyring_store();
        assert!(
            second.is_ok(),
            "second (idempotent) init failed: {second:?}"
        );
    }

    /// Verifies that after a successful `init_keyring_store()` call, the
    /// `KEYRING_INIT` mutex guard contains `Some(())`, confirming the success
    /// is cached for future fast-path returns.
    ///
    /// This test directly inspects the static to confirm caching behavior
    /// beyond what the return value alone proves.
    #[test]
    #[ignore = "requires a running keyring backend (D-Bus Secret Service on Linux)"]
    fn keyring_init_guard_caches_success() {
        // Ensure init has succeeded at least once.
        let result = init_keyring_store();
        assert!(result.is_ok(), "init_keyring_store failed: {result:?}");

        // Inspect the guard directly: it must be Some(()) after success.
        let guard = KEYRING_INIT
            .lock()
            .expect("KEYRING_INIT mutex should not be poisoned");
        assert!(
            guard.is_some(),
            "KEYRING_INIT guard should be Some(()) after successful init"
        );
    }
}
