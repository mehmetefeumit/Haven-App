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
        let mut data = self
            .data
            .write()
            .map_err(|e| IdentityError::Storage(e.to_string()))?;
        data.insert(key.to_string(), value.to_vec());
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
        let mut data = self
            .data
            .write()
            .map_err(|e| IdentityError::Storage(e.to_string()))?;
        data.remove(key);
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
