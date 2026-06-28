//! API bridging layer that exposes haven-core functionality.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use flutter_rust_bridge::frb;

/// Initializes the Rust runtime (logging, panic hooks).
///
/// Called automatically by `RustLib.init()` on the Dart side.
/// Sets up platform-native logging (Android logcat, iOS oslog) so
/// that `log` records from Rust appear in Flutter's debug console.
///
/// # Privacy
///
/// `flutter_rust_bridge::setup_default_user_utils` installs an
/// `android_logger`/`oslog` backend that bridges Rust `log` records
/// to logcat/oslog. That backend is gated on FRB's `log` *feature*,
/// not on the build profile, so it is present in RELEASE too. We must
/// therefore gate the max level on the build profile ourselves:
///
/// - **Debug builds** run at `Debug` so developers (and the E2E
///   integration test) see Haven's `log::debug!` output.
/// - **Release builds** run at `Warn`, so the shipped app does NOT
///   stream verbose internal records (relay URLs, event ids, keyring
///   service/user identifiers, MLS operations) to a world-readable
///   Android logcat. No secret key material is ever logged by Haven
///   in any case — this caps incidental dependency-level disclosure
///   and honors the "no internal state in production logs" posture
///   (CLAUDE.md security rules #6/#8).
///
/// Independently of the level cap, the `keyring_core` crate logs
/// `created entry {:?}` / `get secret from entry {:?}` at `DEBUG`, and the
/// credential's `Debug` embeds the raw secret bytes (the SQLCipher DB keys).
/// In a debug build that level is active, so those bytes would reach a
/// world-readable logcat (and CI log artifacts). We therefore install a
/// filtered `android_logger` BEFORE `setup_default_user_utils` — whose own
/// `init_once` then no-ops — that drops the `keyring_core` target entirely
/// while leaving Haven's own `log::debug!` output intact.
#[frb(init)]
pub fn init_app() {
    // Install our own android_logger FIRST so its per-target filter wins:
    // `android_logger::init_once` is first-call-wins (shared `OnceLock`), so
    // FRB's identical call inside `setup_default_user_utils` below becomes a
    // no-op. The filter drops the `keyring_core` target, which would
    // otherwise log raw DB-key bytes at DEBUG (Security Rule #6); every other
    // target stays at the build-profile level capped below.
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Trace)
            .with_filter(
                android_logger::FilterBuilder::new()
                    .filter_level(log::LevelFilter::Trace)
                    .filter_module("keyring_core", log::LevelFilter::Off)
                    .build(),
            ),
    );

    flutter_rust_bridge::setup_default_user_utils();
    // Cap the global `log` level by build profile. The `android_logger`
    // backend FRB installs is itself release-present (feature-gated, not
    // `debug_assertions`-gated), so the level cap is the control point.
    #[cfg(debug_assertions)]
    log::set_max_level(log::LevelFilter::Debug);
    #[cfg(not(debug_assertions))]
    log::set_max_level(log::LevelFilter::Warn);
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

    /// Processes raw location data and returns a `LocationMessage` with
    /// exact GPS coordinates.
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

/// Location message with exact GPS coordinates (FFI wrapper).
#[derive(Clone)]
#[frb(opaque)]
pub struct LocationMessage {
    inner: haven_core::location::LocationMessage,
}

impl std::fmt::Debug for LocationMessage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocationMessage")
            .field("inner", &"<location data redacted>")
            .finish()
    }
}

impl LocationMessage {
    /// Gets the latitude.
    #[frb(sync)]
    #[must_use]
    pub fn latitude(&self) -> f64 {
        self.inner.latitude
    }

    /// Gets the longitude.
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
    pub fn new(update_interval_minutes: u32) -> Self {
        Self {
            inner: haven_core::location::LocationSettings {
                update_interval_minutes,
            },
        }
    }

    /// Gets the update interval in minutes.
    #[frb(sync)]
    #[must_use]
    pub fn update_interval_minutes(&self) -> u32 {
        self.inner.update_interval_minutes
    }
}

// ============================================================================
// Identity Management
// ============================================================================

/// In-memory secure storage for FFI.
///
/// Flutter should call `store_secret` with data from `flutter_secure_storage`
/// after loading, and call `get_secret_for_storage` before persisting.
#[derive(Default)]
#[frb(ignore)]
struct InMemoryStorage {
    data: RwLock<HashMap<String, Vec<u8>>>,
}

impl std::fmt::Debug for InMemoryStorage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InMemoryStorage")
            .field("data", &"<redacted>")
            .finish()
    }
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
#[derive(Clone)]
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

impl std::fmt::Debug for UnsignedLocationEventFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnsignedLocationEventFfi")
            .field("kind", &self.kind)
            .field("content", &"<redacted>")
            .field("tag_count", &self.tags.len())
            .field("created_at", &self.created_at)
            .finish()
    }
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
    #[frb(sync)]
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

    /// Returns a jittered publish interval in seconds using the Rust-side
    /// CSPRNG (`OsRng`), sampled uniformly in
    /// `[nominal_secs * 0.6, nominal_secs * 1.4]` (40% spread).
    ///
    /// Callers pass the nominal interval (typically 120 s) and rearm their
    /// timer with the returned value. This is NOT the TTL window — the
    /// `expiration` tag sampled inside `encrypt_location` is independent
    /// and intentionally decoupled (see `haven-core/SECURITY.md`).
    ///
    /// On `nominal_secs == 0` the call falls back to `nominal_secs` rather
    /// than panicking, so a zero at the boundary does not silently
    /// reschedule at 0 s. Dart callers should pass a positive nominal.
    #[frb(sync)]
    #[must_use]
    pub fn jittered_publish_interval_secs(&self, nominal_secs: u64) -> u64 {
        haven_core::location::compute_jittered_publish_interval_secs(
            nominal_secs,
            haven_core::location::PUBLISH_INTERVAL_JITTER_FRACTION_BP,
        )
        .unwrap_or(nominal_secs)
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

/// Installs an in-memory keyring backend for E2E tests.
///
/// Intended exclusively for hermetic test harnesses on CI runners that lack
/// a platform credential store (e.g., Linux runners with no D-Bus Secret
/// Service). The backing storage is process-local and dropped when the
/// process exits — secrets never touch disk.
///
/// Must be called **before** [`init_keyring_store`]. If a platform backend
/// has already been installed (`KEYRING_INIT.is_some()`), this call is a
/// no-op so test setup can be defensive about ordering.
///
/// Idempotent: calling twice returns `Ok(())` on the second call.
///
/// # Errors
///
/// * Returns an error if the keyring init mutex is poisoned.
/// * Returns an error if the in-memory store cannot be constructed
///   (the upstream `keyring_core::mock::Store::new()` does not fail in
///   practice, but the boundary is preserved for forward compatibility).
/// * In release builds this function is unreachable; the sibling stub
///   always returns an error.
#[cfg(debug_assertions)]
pub fn use_in_memory_keyring_for_test() -> Result<(), String> {
    let mut guard = KEYRING_INIT
        .lock()
        .map_err(|e| format!("Keyring lock poisoned: {e}"))?;
    if guard.is_some() {
        // A backend (platform or in-memory) is already installed. Treat this
        // as idempotent success so test setup that races init paths does
        // not surface as a flaky failure.
        return Ok(());
    }
    let store = crate::test_keyring::build_in_memory_store()?;
    keyring_core::set_default_store(store);
    *guard = Some(());
    Ok(())
}

/// Release-build stub for [`use_in_memory_keyring_for_test`].
///
/// Returns an error so release callers fail closed — the in-memory backend
/// is physically unreachable in release builds (the `test_keyring` module is
/// gated on `#[cfg(debug_assertions)]`).
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn use_in_memory_keyring_for_test() -> Result<(), String> {
    Err("use_in_memory_keyring_for_test is disabled in release builds".to_string())
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
const CIRCLES_DB_SERVICE: &str = "com.oblivioustech.haven";

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

    let key = match entry.get_secret() {
        Ok(secret_bytes) => {
            // Key exists — wrap in Zeroizing to ensure zeroing on drop, then hex-encode
            let secret_bytes = zeroize::Zeroizing::new(secret_bytes);
            zeroize::Zeroizing::new(hex::encode(&*secret_bytes))
        }
        Err(keyring_core::Error::NoEntry) => {
            // Key doesn't exist — generate and store a new one
            let mut key_bytes = zeroize::Zeroizing::new([0u8; 32]);
            rand::rngs::OsRng.fill_bytes(key_bytes.as_mut());

            entry
                .set_secret(key_bytes.as_ref())
                .map_err(|e| format!("Failed to store circles.db key in keyring: {e}"))?;

            zeroize::Zeroizing::new(hex::encode(key_bytes.as_ref()))
        }
        Err(keyring_core::Error::NoStorageAccess(err)) => {
            return Err(format!("Keyring not accessible for circles.db key: {err}"));
        }
        Err(e) => return Err(format!("Failed to retrieve circles.db key: {e}")),
    };

    // On iOS, migrate the circles.db key (born `WhenUnlocked`) to
    // `AfterFirstUnlockThisDeviceOnly` so a locked-device background wake can
    // open the database. No-op on every other target. Non-fatal: the migration
    // restores the key on any failure, so we log a redacted warning and return
    // the (unchanged) key.
    if let Err(e) = haven_core::keyring_policy::ensure_db_key_after_first_unlock(
        CIRCLES_DB_SERVICE,
        CIRCLES_DB_KEY_ID,
    ) {
        log::warn!("circles.db key access-policy migration deferred: {e}");
    }

    Ok(key)
}

// ============================================================================
// Tile Cache (tiles.db) — Encrypted Map-Tile Cache (FFI)
// ============================================================================

use haven_core::tiles::{TileCacheError, TileCacheStorage, TileEntry};

/// Keyring service identifier for the tiles.db encryption key.
const TILES_DB_SERVICE: &str = "com.oblivioustech.haven";

/// Keyring key identifier for the tiles.db encryption key.
const TILES_DB_KEY_ID: &str = "tiles.db.key";

/// On-disk filename for the encrypted tile cache (with `-wal`/`-shm` sidecars).
const TILES_DB_FILENAME: &str = "tiles.db";

/// The live encrypted tile cache, shared across FFI calls.
///
/// `RwLock<Option<Arc<...>>>`: cloning the `Arc` under a read lock lets every
/// tile call run concurrently against the same storage (which has its own
/// internal read/write connection split). Set to `None` by [`tile_cache_wipe`]
/// so the last `Arc` drop closes the connections.
static TILE_CACHE: RwLock<Option<Arc<TileCacheStorage>>> = RwLock::new(None);

/// Remembers the data directory passed to [`tile_cache_init`] so the wipe path
/// can delete `tiles.db` + its `-wal`/`-shm` sidecars by absolute path.
static TILE_CACHE_DIR: Mutex<Option<String>> = Mutex::new(None);

/// Returns the current unix time in **milliseconds**.
///
/// Clamped to `i64`; a clock before the unix epoch yields a negative value,
/// which is harmless for the cache's relative-age arithmetic.
fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Maps a [`TileCacheError`] to a generic boundary string.
///
/// The error types are already redaction-safe (their `Display` never carries
/// coordinates, bytes, or key material), but this keeps the FFI surface uniform
/// and ensures no tile `(z, x, y)` can ever reach Dart.
fn tile_err_to_string(err: &TileCacheError) -> String {
    err.to_string()
}

/// Retrieves or creates the tiles.db encryption key from the system keyring.
///
/// Near-copy of [`get_or_create_circle_db_key`]: on first call it generates a
/// 256-bit `OsRng` key, stores the raw bytes in the platform keyring, and
/// returns the hex-encoded key; subsequent calls retrieve and hex-encode it.
///
/// # Errors
///
/// Returns an error string if the keyring cannot be accessed or key generation
/// fails.
fn get_or_create_tiles_db_key() -> Result<zeroize::Zeroizing<String>, String> {
    use rand::RngCore;

    let entry = keyring_core::Entry::new(TILES_DB_SERVICE, TILES_DB_KEY_ID)
        .map_err(|e| format!("Failed to create keyring entry for tiles.db: {e}"))?;

    let key = match entry.get_secret() {
        Ok(secret_bytes) => {
            let secret_bytes = zeroize::Zeroizing::new(secret_bytes);
            zeroize::Zeroizing::new(hex::encode(&*secret_bytes))
        }
        Err(keyring_core::Error::NoEntry) => {
            let mut key_bytes = zeroize::Zeroizing::new([0u8; 32]);
            rand::rngs::OsRng.fill_bytes(key_bytes.as_mut());

            entry
                .set_secret(key_bytes.as_ref())
                .map_err(|e| format!("Failed to store tiles.db key in keyring: {e}"))?;

            zeroize::Zeroizing::new(hex::encode(key_bytes.as_ref()))
        }
        Err(keyring_core::Error::NoStorageAccess(err)) => {
            return Err(format!("Keyring not accessible for tiles.db key: {err}"));
        }
        Err(e) => return Err(format!("Failed to retrieve tiles.db key: {e}")),
    };

    // On iOS, migrate the tiles.db key (born `WhenUnlocked`) to
    // `AfterFirstUnlockThisDeviceOnly` so a locked-device background wake can
    // open the cache. No-op on every other target. Non-fatal: the migration
    // restores the key on any failure, so we log a redacted warning and return
    // the (unchanged) key.
    if let Err(e) = haven_core::keyring_policy::ensure_db_key_after_first_unlock(
        TILES_DB_SERVICE,
        TILES_DB_KEY_ID,
    ) {
        log::warn!("tiles.db key access-policy migration deferred: {e}");
    }

    Ok(key)
}

/// Best-effort removal of the tiles.db keyring entry.
///
/// Ignores `NoEntry` (already gone). Used by the disposable-cache recovery and
/// the logout wipe.
fn remove_tiles_db_key() {
    if let Ok(entry) = keyring_core::Entry::new(TILES_DB_SERVICE, TILES_DB_KEY_ID) {
        let _ = entry.delete_credential();
    }
}

/// Best-effort deletion of `tiles.db` and its WAL/SHM/journal sidecars under
/// `data_dir`.
///
/// The `-wal`/`-shm` sidecars hold `SQLCipher`-encrypted pages that have not yet
/// been checkpointed into the main file, so they MUST be deleted alongside it on
/// wipe — otherwise cached map areas could linger at rest. `-journal` is included
/// for defense-in-depth: although WAL mode normally precludes a rollback journal,
/// SQLite can transiently fall back to one (e.g. during VACUUM/checkpoint), so we
/// delete it too. Missing files are not an error.
fn delete_tile_db_files(data_dir: &str) {
    let base = std::path::Path::new(data_dir).join(TILES_DB_FILENAME);
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let path = if suffix.is_empty() {
            base.clone()
        } else {
            let mut s = base.clone().into_os_string();
            s.push(suffix);
            std::path::PathBuf::from(s)
        };
        let _ = std::fs::remove_file(&path);
    }
}

/// A cached tile and its conditional-revalidation metadata, for Dart.
///
/// `bytes` is public map imagery (encrypted only at rest), so it is surfaced
/// directly. No coordinates are carried, and there is intentionally no `Debug`
/// impl that prints `bytes`.
pub struct TileCacheEntryFfi {
    /// Raw tile bytes (PNG).
    pub bytes: Vec<u8>,
    /// HTTP freshness deadline in unix milliseconds.
    pub stale_at_ms: i64,
    /// `Last-Modified` as unix milliseconds, if present.
    pub last_modified_ms: Option<i64>,
    /// `ETag` value, if present.
    pub etag: Option<String>,
}

impl From<TileEntry> for TileCacheEntryFfi {
    fn from(e: TileEntry) -> Self {
        Self {
            bytes: e.bytes,
            stale_at_ms: e.stale_at_ms,
            last_modified_ms: e.last_modified_ms,
            etag: e.etag,
        }
    }
}

/// Clones the live tile-cache `Arc` under a read lock.
///
/// # Errors
///
/// Returns an error string if the cache is not initialized or the lock is
/// poisoned.
fn current_cache() -> Result<Arc<TileCacheStorage>, String> {
    let guard = TILE_CACHE
        .read()
        .map_err(|_| "tile cache lock poisoned".to_string())?;
    guard
        .as_ref()
        .cloned()
        .ok_or_else(|| "tile cache not initialized".to_string())
}

/// Initializes the encrypted tile cache at `data_dir`/`tiles.db`.
///
/// Ensures the platform keyring is initialized, fetches/creates the tiles.db
/// key, and opens the cache. On a decrypt failure or schema-version mismatch the
/// cache is **disposable**: it is dropped and recreated (delete the DB files,
/// remove the keyring entry, mint a fresh key, reopen) so the map is never
/// blocked. Other errors are returned (Dart treats the cache as unavailable and
/// falls back to live tiles).
///
/// This is a plain `pub fn`; `flutter_rust_bridge` dispatches it on a worker, so
/// the one-time `SQLCipher` open at startup does not block the UI isolate.
///
/// # Errors
///
/// Returns an error string if the keyring is unavailable or the cache cannot be
/// opened even after disposable recovery.
pub fn tile_cache_init(data_dir: String) -> Result<(), String> {
    init_keyring_store()?;

    // Ensure the data directory exists. `tile_cache_init` runs from `main()`
    // before the lazily-constructed `CircleManagerFfi` (which is the usual
    // creator of this directory via `create_dir_all`), so on a fresh install
    // the directory would not yet exist and `Connection::open` — which creates
    // the DB file but NOT its parent dirs — would fail, silently disabling the
    // cache for the whole first session. Create it here so init is self-
    // sufficient regardless of call order.
    std::fs::create_dir_all(&data_dir)
        .map_err(|e| format!("Failed to create tile cache data dir: {e}"))?;

    let path = std::path::Path::new(&data_dir).join(TILES_DB_FILENAME);

    let key = get_or_create_tiles_db_key()?;
    let storage = match TileCacheStorage::open(&path, &key) {
        Ok(s) => s,
        Err(TileCacheError::DecryptFailed | TileCacheError::SchemaVersionMismatch) => {
            // Disposable-cache recovery: the cache holds only re-fetchable public
            // imagery, so on a corrupt/undecryptable/stale-schema DB we drop and
            // recreate it rather than blocking the map.
            log::warn!("tiles.db unreadable; recreating disposable tile cache");
            drop(key);
            delete_tile_db_files(&data_dir);
            remove_tiles_db_key();
            let fresh_key = get_or_create_tiles_db_key()?;
            TileCacheStorage::open(&path, &fresh_key).map_err(|e| tile_err_to_string(&e))?
        }
        Err(e) => return Err(tile_err_to_string(&e)),
    };

    {
        let mut guard = TILE_CACHE
            .write()
            .map_err(|_| "tile cache lock poisoned".to_string())?;
        *guard = Some(Arc::new(storage));
    }
    {
        let mut dir = TILE_CACHE_DIR
            .lock()
            .map_err(|_| "tile cache dir lock poisoned".to_string())?;
        *dir = Some(data_dir);
    }
    Ok(())
}

/// Returns the cached tile for `(style, z, x, y, retina)`, or `None`.
///
/// # Errors
///
/// Returns an error string if the cache is uninitialized or the read fails.
/// Coordinates are never included in the error.
pub async fn tile_cache_get(
    style: String,
    z: i64,
    x: i64,
    y: i64,
    retina: bool,
) -> Result<Option<TileCacheEntryFfi>, String> {
    let cache = current_cache()?;
    run_blocking(move || {
        cache
            .get(&style, z, x, y, retina, now_ms())
            .map(|opt| opt.map(TileCacheEntryFfi::from))
            .map_err(|e| tile_err_to_string(&e))
    })
    .await
}

/// Inserts or replaces a tile's bytes and metadata (a bytes-write).
///
/// # Errors
///
/// Returns an error string if the cache is uninitialized or the write fails.
#[allow(
    clippy::too_many_arguments,
    reason = "the tile key + payload is inherently wide; grouping would change the wire contract"
)]
pub async fn tile_cache_put(
    style: String,
    z: i64,
    x: i64,
    y: i64,
    retina: bool,
    bytes: Vec<u8>,
    stale_at_ms: i64,
    last_modified_ms: Option<i64>,
    etag: Option<String>,
) -> Result<(), String> {
    let cache = current_cache()?;
    run_blocking(move || {
        cache
            .put(
                &style,
                z,
                x,
                y,
                retina,
                &bytes,
                stale_at_ms,
                last_modified_ms,
                etag.as_deref(),
                now_ms(),
            )
            .map_err(|e| tile_err_to_string(&e))
    })
    .await
}

/// Refreshes only a tile's conditional-revalidation metadata (the HTTP-304
/// path); never touches the bytes or the `fetched_at` anchor.
///
/// # Errors
///
/// Returns an error string if the cache is uninitialized or the update fails.
#[allow(
    clippy::too_many_arguments,
    reason = "mirrors the tile key + metadata shape of `tile_cache_put`"
)]
pub async fn tile_cache_put_metadata(
    style: String,
    z: i64,
    x: i64,
    y: i64,
    retina: bool,
    stale_at_ms: i64,
    last_modified_ms: Option<i64>,
    etag: Option<String>,
) -> Result<(), String> {
    let cache = current_cache()?;
    run_blocking(move || {
        cache
            .put_metadata(
                &style,
                z,
                x,
                y,
                retina,
                stale_at_ms,
                last_modified_ms,
                etag.as_deref(),
                now_ms(),
            )
            .map_err(|e| tile_err_to_string(&e))
    })
    .await
}

/// Evicts stale, over-retention, and over-budget tiles in one transaction.
///
/// `idle_age_secs` and `max_retention_secs` are converted to milliseconds to
/// match the storage layer's unix-millisecond clocks.
///
/// Returns the number of rows deleted.
///
/// # Errors
///
/// Returns an error string if the cache is uninitialized or the eviction fails.
pub async fn tile_cache_evict(
    max_bytes: i64,
    idle_age_secs: i64,
    max_retention_secs: i64,
) -> Result<u64, String> {
    let cache = current_cache()?;
    let idle_age_ms = idle_age_secs.saturating_mul(1000);
    let max_retention_ms = max_retention_secs.saturating_mul(1000);
    run_blocking(move || {
        cache
            .evict(max_bytes, idle_age_ms, max_retention_ms, now_ms())
            .map_err(|e| tile_err_to_string(&e))
    })
    .await
}

/// Wipes the encrypted tile cache (logout path).
///
/// Best-effort clears the content, drops the live `Arc` (closing the
/// connections once the last reference is gone), deletes `tiles.db` + its
/// `-wal`/`-shm` sidecars, and removes the tiles keyring entry. Already-gone
/// files are not an error: a new identity must never inherit the prior
/// identity's cached map areas.
///
/// # Errors
///
/// Returns an error string only if an internal lock is poisoned.
pub async fn tile_cache_wipe() -> Result<(), String> {
    // Best-effort content clear while the cache is still live.
    if let Ok(cache) = current_cache() {
        let _ = run_blocking(move || cache.clear().map_err(|e| tile_err_to_string(&e))).await;
    }

    // Drop the live Arc so the connections close once the last ref is gone.
    //
    // Race note (SF-2): a `tile_cache_get/put` that called `current_cache()`
    // just before this `take` holds its own Arc clone, so its connection
    // briefly outlives the wipe. This is POSIX-safe — `remove_file` unlinks but
    // defers reclamation until the last fd closes, and that in-flight call
    // writes no *new* at-rest data (a `get` is read-only; a racing `put` lands
    // in a file we are unlinking, under a key we are about to remove). The M-C
    // logout path must still cancel prefetch/tile traffic before calling this
    // so no such race is in flight in practice.
    {
        let mut guard = TILE_CACHE
            .write()
            .map_err(|_| "tile cache lock poisoned".to_string())?;
        *guard = None;
    }

    // Delete the DB files (+ sidecars) using the remembered data dir.
    let data_dir = {
        let dir = TILE_CACHE_DIR
            .lock()
            .map_err(|_| "tile cache dir lock poisoned".to_string())?;
        dir.clone()
    };
    if let Some(dir) = data_dir {
        delete_tile_db_files(&dir);
    }

    // Remove the keyring entry so a fresh cache mints a fresh key.
    remove_tiles_db_key();
    Ok(())
}

// ============================================================================
// Circle Management (FFI)
// ============================================================================

use std::path::Path;

use haven_core::circle::{
    AvatarAssignmentMeta as CoreAvatarMeta, AvatarIngestResult as CoreAvatarIngestResult,
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
#[derive(Clone)]
pub struct ContactFfi {
    /// Nostr public key (hex) - the ONLY identifier visible to relays.
    pub pubkey: String,
    /// Locally assigned display name.
    pub display_name: Option<String>,
    /// Optional notes about this contact.
    pub notes: Option<String>,
    /// When this contact was created (Unix timestamp).
    pub created_at: i64,
    /// When this contact was last updated (Unix timestamp).
    pub updated_at: i64,
}

impl std::fmt::Debug for ContactFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContactFfi")
            .field(
                "pubkey",
                &format_args!("{}...", &self.pubkey[..16.min(self.pubkey.len())]),
            )
            .field("display_name", &"<redacted>")
            .field("notes", &"<redacted>")
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .finish()
    }
}

impl From<&CoreContact> for ContactFfi {
    fn from(c: &CoreContact) -> Self {
        Self {
            pubkey: c.pubkey.clone(),
            display_name: c.display_name.clone(),
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
    /// Whether this member is a group admin.
    pub is_admin: bool,
}

impl From<&CoreCircleMember> for CircleMemberFfi {
    fn from(m: &CoreCircleMember) -> Self {
        Self {
            pubkey: m.pubkey.clone(),
            display_name: m.display_name.clone(),
            is_admin: m.is_admin,
        }
    }
}

/// Metadata about a stored avatar (no image bytes).
///
/// Returned by [`CircleManagerFfi::set_my_avatar`] so the UI can update state
/// (e.g. invalidate a thumbnail provider) without shipping the image until it
/// is explicitly requested. The content hash is the user's OWN avatar hash.
#[derive(Clone)]
pub struct AvatarMetaFfi {
    /// Hex SHA-256 of the canonical image (content address).
    pub content_hash_hex: String,
    /// MIME type (e.g. `image/jpeg`).
    pub mime: String,
    /// Canonical width in pixels.
    pub width: u32,
    /// Canonical height in pixels.
    pub height: u32,
    /// Monotonic avatar version.
    pub version: i64,
}

impl std::fmt::Debug for AvatarMetaFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the content hash (Security Rule #8).
        f.debug_struct("AvatarMetaFfi")
            .field("content_hash_hex", &"<redacted>")
            .field("mime", &self.mime)
            .field("width", &self.width)
            .field("height", &self.height)
            .field("version", &self.version)
            .finish()
    }
}

impl From<CoreAvatarMeta> for AvatarMetaFfi {
    fn from(m: CoreAvatarMeta) -> Self {
        Self {
            content_hash_hex: hash_to_hex(&m.content_hash),
            mime: m.mime,
            width: m.width,
            height: m.height,
            version: m.version,
        }
    }
}

/// Outcome of ingesting one incoming kind-445 event through the avatar path.
///
/// Carries NO image bytes — only flags + the MLS-authenticated sender pubkey so
/// the Dart layer can decide whether to invalidate a member's thumbnail
/// provider. A non-avatar event (location, group update, unknown inner type)
/// returns `accepted = false`, `complete = false`, `sender_pubkey_hex = None`.
#[derive(Clone)]
pub struct AvatarIngestResultFfi {
    /// `true` if a manifest/chunk was accepted, a complete avatar stored, or a
    /// tombstone applied.
    pub accepted: bool,
    /// `true` if an avatar (or clear) completed on this event.
    pub complete: bool,
    /// MLS-authenticated sender pubkey (hex) for an accepted avatar event;
    /// `None` for ignored events.
    pub sender_pubkey_hex: Option<String>,
    /// Avatar version on completion; `None` otherwise.
    pub version: Option<i64>,
}

impl std::fmt::Debug for AvatarIngestResultFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The sender pubkey is a public relay-visible identity but we keep
        // output minimal; never print it raw here.
        f.debug_struct("AvatarIngestResultFfi")
            .field("accepted", &self.accepted)
            .field("complete", &self.complete)
            .field("has_sender", &self.sender_pubkey_hex.is_some())
            .field("version", &self.version)
            .finish()
    }
}

impl From<CoreAvatarIngestResult> for AvatarIngestResultFfi {
    fn from(r: CoreAvatarIngestResult) -> Self {
        Self {
            accepted: r.accepted,
            complete: r.complete,
            sender_pubkey_hex: r.sender_pubkey_hex,
            version: r.version,
        }
    }
}

/// Encodes a 32-byte hash as lowercase hex (dependency-free).
fn hash_to_hex(bytes: &[u8; 32]) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(64);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
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

/// A signed key package event pair ready for relay publishing (FFI-friendly).
///
/// During the kind 443 → 30443 transition (per MIP-00 / MDK), publishers sign
/// both the canonical addressable event (kind 30443) and the legacy
/// non-replaceable twin (kind 443) from the same MLS key material so that
/// clients which haven't migrated to 30443 yet can still discover this user.
///
/// The two events share `content` and `hash_ref`; only the tag set differs
/// (the legacy twin omits the `d` tag). The pair carries a single relay list
/// so callers fan-out the same URLs.
#[derive(Debug, Clone)]
pub struct SignedKeyPackageEventFfi {
    /// The canonical kind 30443 (addressable) signed event as JSON string.
    pub event_json: String,
    /// The legacy kind 443 signed event as JSON string.
    ///
    /// Publish best-effort: relays/clients that have already migrated may
    /// reject or ignore this twin, but we keep publishing it to remain
    /// discoverable by clients that still query kind 443.
    pub legacy_event_json: String,
    /// Relay URLs where both events should be published.
    pub relays: Vec<String>,
}

/// A member's key package with their inbox relay list (FFI-friendly).
///
/// Used when adding members to a circle. Relay resolution follows a
/// cascading fallback: inbox (kind 10050) → NIP-65 (kind 10002) → defaults.
#[derive(Clone)]
pub struct MemberKeyPackageFfi {
    /// The key package event JSON (kind 30443 or legacy kind 443).
    pub key_package_json: String,
    /// Relay URLs from the member's inbox relay list (kind 10050).
    pub inbox_relays: Vec<String>,
    /// Fallback relay URLs from NIP-65 relay list (kind 10002).
    pub nip65_relays: Vec<String>,
}

impl std::fmt::Debug for MemberKeyPackageFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemberKeyPackageFfi")
            .field("key_package_json", &"<redacted>")
            .field("inbox_relays_count", &self.inbox_relays.len())
            .field("nip65_relays_count", &self.nip65_relays.len())
            .finish()
    }
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
            .field("recipient_relays_count", &self.recipient_relays.len())
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

/// Result of adding members to an existing circle (FFI-friendly).
#[derive(Clone)]
pub struct AddMembersResultFfi {
    /// JSON-serialized kind 445 evolution (Add commit) event, to publish to
    /// the circle's relays before finalizing the pending commit.
    pub evolution_event_json: String,
    /// Gift-wrapped Welcome events for the newly added members.
    /// Each is a kind 1059 event containing an encrypted kind 444 Welcome.
    /// Publish these only after the evolution event is published and merged.
    pub welcome_events: Vec<GiftWrappedWelcomeFfi>,
}

impl std::fmt::Debug for AddMembersResultFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The evolution-event JSON can embed the MLS group ID in its tags;
        // redact it. Welcome events redact themselves via their own Debug impl.
        f.debug_struct("AddMembersResultFfi")
            .field("evolution_event_json", &"<redacted>")
            .field("welcome_events_count", &self.welcome_events.len())
            .finish()
    }
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
#[derive(Clone)]
pub struct DecryptedLocationFfi {
    /// Sender's Nostr public key (hex-encoded).
    pub sender_pubkey: String,
    /// Latitude (exact GPS reading).
    pub latitude: f64,
    /// Longitude (exact GPS reading).
    pub longitude: f64,
    /// Geohash of the location.
    pub geohash: String,
    /// When the location was recorded (Unix seconds).
    pub timestamp: i64,
    /// When this location expires (Unix seconds).
    pub expires_at: i64,
    /// Sender's self-chosen display name (if provided).
    pub display_name: Option<String>,
}

impl std::fmt::Debug for DecryptedLocationFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DecryptedLocationFfi")
            .field("sender_pubkey", &"<redacted>")
            .field("latitude", &"<redacted>")
            .field("longitude", &"<redacted>")
            .field("geohash", &"<redacted>")
            .field("display_name", &"<redacted>")
            .field("timestamp", &self.timestamp)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// A persisted last-known location for a circle member (FFI-friendly).
///
/// Mirrors `haven_core::circle::LastKnownLocation`. Returned from
/// `CircleManagerFfi::snapshot_last_known_for_circle` so the Flutter
/// layer can hydrate its in-memory cache on app start.
#[derive(Clone)]
pub struct LastKnownLocationFfi {
    /// Nostr group ID (32 bytes) of the circle.
    pub nostr_group_id: Vec<u8>,
    /// Sender's Nostr public key (hex-encoded).
    pub sender_pubkey: String,
    /// Latitude (exact GPS reading).
    pub latitude: f64,
    /// Longitude (exact GPS reading).
    pub longitude: f64,
    /// Geohash of the location.
    pub geohash: String,
    /// Display name carried in the encrypted location message, if any.
    pub display_name: Option<String>,
    /// When the location was captured (Unix seconds).
    pub timestamp: i64,
    /// When the inner freshness window expires (Unix seconds).
    pub expires_at: i64,
    /// Row must be deleted after this Unix-seconds moment.
    pub purge_after: i64,
    /// When this row was last written (Unix seconds, receiver clock).
    pub updated_at: i64,
}

impl std::fmt::Debug for LastKnownLocationFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LastKnownLocationFfi")
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

/// Result of processing a kind 445 MLS group event (FFI-friendly).
///
/// Distinguishes between location messages and MLS group state changes
/// (commits, proposals) so the Flutter layer can refresh circle membership
/// when the group roster changes.
#[derive(Clone)]
pub struct DecryptResultFfi {
    /// The decrypted location, if this was an application message.
    /// `None` for group updates and unprocessable events.
    pub location: Option<DecryptedLocationFfi>,
    /// `true` when the event was an MLS commit or proposal that changed
    /// the group state (e.g., a new member joined). The Flutter layer
    /// should refresh the circle's member list when this is `true`.
    pub group_updated: bool,
    /// Outbound `kind:445` commit event the Flutter layer must publish
    /// to the circle's relays and then merge locally.
    ///
    /// Populated only when MDK auto-commits a peer's `SelfRemove`
    /// proposal (MLS leave): MDK stages a pending commit and the caller
    /// owes a publish-then-merge cycle so the local epoch advances and
    /// the leaver stops appearing in the roster.
    ///
    /// `None` for location messages, plain commits (already merged by
    /// MDK on the sender side), pending Add/Remove proposals awaiting
    /// admin approval, external join proposals, ignored proposals, and
    /// unprocessable events.
    pub evolution_event_json: Option<String>,
    /// MLS group ID (raw bytes) the evolution event belongs to.
    ///
    /// Carried alongside `evolution_event_json` so the Flutter layer can
    /// invoke `finalizePendingCommit` / `clearPendingCommit` after the
    /// publish attempt. `None` for every variant where
    /// `evolution_event_json` is also `None`.
    pub evolution_mls_group_id: Option<Vec<u8>>,
}

impl std::fmt::Debug for DecryptResultFfi {
    /// Redacts the evolution event JSON (may embed the MLS group ID in
    /// its `h` tag) and the raw MLS group ID bytes. Mirrors the redaction
    /// policy on [`LocationMessageResult::GroupUpdate`]'s core `Debug` impl.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DecryptResultFfi")
            .field("has_location", &self.location.is_some())
            .field("group_updated", &self.group_updated)
            .field("has_evolution_event", &self.evolution_event_json.is_some())
            .field(
                "has_evolution_mls_group_id",
                &self.evolution_mls_group_id.is_some(),
            )
            .finish()
    }
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

/// Discriminator for [`LeavePlanFfi`].
///
/// Drives the Flutter-side leave state machine. See the core
/// `LeavePlan` docs for the full flow per variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeavePlanKindFfi {
    /// Caller is a non-admin — skip handoff/demotion, go to `propose_leave`.
    NonAdmin,
    /// Caller is the sole admin — must promote `successor_hex` before
    /// self-demoting and leaving.
    AdminHandoff,
    /// Caller is one of multiple admins — skip promotion and go directly
    /// to `propose_self_demote` + `propose_leave`.
    AdminDemote,
    /// Caller is the sole remaining member — call
    /// `abandon_circle_local_only` to wipe the local row.
    Abandon,
    /// MDK has no record of the group — call `complete_leave` to wipe the
    /// orphaned local row.
    OrphanLocalOnly,
}

/// FFI mirror of [`haven_core::circle::LeavePlan`].
///
/// Struct shape (rather than tagged enum) avoids pulling in Dart `freezed`
/// for sealed classes while preserving all the information.
#[derive(Clone)]
pub struct LeavePlanFfi {
    /// Which branch of the state machine to execute.
    pub kind: LeavePlanKindFfi,
    /// Hex-encoded successor pubkey when `kind == AdminHandoff`, else `None`.
    pub successor_hex: Option<String>,
}

impl std::fmt::Debug for LeavePlanFfi {
    /// Redacts `successor_hex` to an 8-char prefix so log lines cannot be
    /// used to correlate a user to a specific handoff.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let redacted = self
            .successor_hex
            .as_deref()
            .map(|h| h.chars().take(8).collect::<String>() + "…");
        f.debug_struct("LeavePlanFfi")
            .field("kind", &self.kind)
            .field("successor_hex", &redacted)
            .finish()
    }
}

// ==================== Relay preferences (kind 10050 / 10051) ====================
//
// FFI mirror of `haven_core::circle::RelayType`. Compile-time exhaustive on
// the Dart side so we never round-trip a stringly-typed slug across the
// boundary. Conversions live next to the type so they are easy to audit.

/// Category of relay preference managed per user.
///
/// Mirrors [`haven_core::circle::RelayType`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayTypeFfi {
    /// Inbox relays (kind 10050, NIP-17).
    Inbox,
    /// `KeyPackage` relays (kind 10051, MIP-00).
    KeyPackage,
}

impl From<RelayTypeFfi> for haven_core::circle::RelayType {
    fn from(t: RelayTypeFfi) -> Self {
        match t {
            RelayTypeFfi::Inbox => Self::Inbox,
            RelayTypeFfi::KeyPackage => Self::KeyPackage,
        }
    }
}

impl From<haven_core::circle::RelayType> for RelayTypeFfi {
    fn from(t: haven_core::circle::RelayType) -> Self {
        match t {
            haven_core::circle::RelayType::Inbox => Self::Inbox,
            haven_core::circle::RelayType::KeyPackage => Self::KeyPackage,
        }
    }
}

/// Outcome of a [`CircleManagerFfi::build_relay_list_publish`] call.
///
/// The FFI builds the signed event AND resolves the publish targets
/// atomically with the toggle check, then hands them to Dart. Dart must
/// publish using the returned `targets` exactly — it must NOT widen them
/// or fall back to a Dart-side default. The toggle integrity guarantee
/// rests on the fact that Dart cannot get an event without first calling
/// this method, which short-circuits to `suppressed=true` when the toggle
/// is off.
#[derive(Debug, Clone)]
pub struct BuiltRelayListEventFfi {
    /// Signed event JSON, ready for `RelayManagerFfi::publish_event`.
    /// `None` when `suppressed` is `true`.
    pub event_json: Option<String>,
    /// Hex-encoded event id; `None` when suppressed.
    pub event_id_hex: Option<String>,
    /// Resolved publish targets — the user's own configured relays for
    /// `relay_type`, deduplicated and nothing else. Two-plane model: the
    /// public default set is NEVER force-unioned in, so a private relay is
    /// never published to a public relay. Empty when suppressed.
    pub targets: Vec<String>,
    /// Numeric Nostr kind (10050 or 10051). `None` when suppressed.
    pub kind: Option<u16>,
    /// Unix-seconds `created_at` from the signed event. Pass this back
    /// to [`CircleManagerFfi::record_published_relay_list`] so the
    /// recorded `published_at` matches the timestamp other relays will
    /// see — this is what
    /// [`haven_core::relay::publishers::build_unpublish_event`] reads to
    /// defeat clock skew on the next replacement.
    pub created_at_secs: Option<i64>,
    /// `true` when the user's privacy toggle is OFF for this category;
    /// the caller must NOT publish anything in this case.
    pub suppressed: bool,
}

/// Outcome of [`CircleManagerFfi::build_unpublish_relay_list`].
///
/// Two events: the empty-replacement (always populated when not suppressed)
/// and the optional NIP-09 deletion (populated only when a previously
/// published event is on record).
#[derive(Debug, Clone)]
pub struct BuiltUnpublishFfi {
    /// Empty-replacement event JSON. Always populated when `suppressed`
    /// is false.
    pub replacement_event_json: Option<String>,
    /// Best-effort NIP-09 deletion JSON. Populated only when a prior
    /// publication was recorded.
    pub deletion_event_json: Option<String>,
    /// Resolved targets. For `build_unpublish_relay_list` (full opt-out)
    /// these are the user's own configured relays (no default union). For
    /// `build_relay_removal_scrub` these are the specific dropped relays.
    pub targets: Vec<String>,
    /// `true` when nothing should be published (no prior record AND
    /// toggle was already off — there's nothing to unpublish).
    pub suppressed: bool,
}

/// Converts a signed nostr `Event` (kind 445) into a `SignedEventFfi`.
fn signed_event_to_ffi(e: &nostr::Event) -> SignedEventFfi {
    SignedEventFfi {
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
    }
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
use haven_core::validation::{normalize_pubkey_hex, parse_nostr_group_id, validate_pubkey_hex};

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
/// Parses a `Vec<Vec<String>>` tag list (as returned by `KeyPackageBundle`)
/// into nostr `Tag` values. Returns a structured error string on the first
/// malformed tag.
#[inline]
fn parse_kp_tags(tags: &[Vec<String>]) -> Result<Vec<nostr::Tag>, String> {
    tags.iter()
        .map(|tag_vec| {
            nostr::Tag::parse(tag_vec).map_err(|e| format!("Failed to parse key package tag: {e}"))
        })
        .collect()
}

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
    /// * `creator_fallback_relays` - The creator's own inbox relays (kind
    ///   10050), used as the third tier in the Welcome delivery cascade
    ///   (member 10050 → member 10002 → creator inbox → FAIL CLOSED). Pass an
    ///   empty list if the creator has no inbox relays; delivery then fails
    ///   closed (no public-default fallback) when tiers 1–2 are also empty.
    ///
    /// # Security
    ///
    /// The Welcome events are gift-wrapped per NIP-59, hiding the sender's
    /// identity behind an ephemeral key. Each Welcome uses a fresh ephemeral
    /// keypair and randomized timestamp.
    //
    // The FFI signature is dictated by the Flutter-Rust contract (one Dart
    // argument per Rust parameter); grouping these into a struct would
    // change the generated bindings. The arity is reviewed at the
    // architectural level, not by clippy.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_circle(
        &self,
        identity_secret_bytes: Vec<u8>,
        members: Vec<MemberKeyPackageFfi>,
        name: String,
        description: Option<String>,
        circle_type: String,
        relays: Vec<String>,
        creator_fallback_relays: Vec<String>,
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
                    nip65_relays: m.nip65_relays,
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
            .create_circle(
                &keys,
                member_key_packages,
                &config,
                &creator_fallback_relays,
            )
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

    /// Classifies the leave operation — see [`LeavePlanFfi`] for the
    /// Flutter-side state machine.
    pub async fn plan_leave(
        &self,
        mls_group_id: Vec<u8>,
        self_pubkey_hex: String,
    ) -> Result<LeavePlanFfi, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            let self_pk = nostr::PublicKey::from_hex(&self_pubkey_hex)
                .map_err(|_| "Invalid self_pubkey_hex".to_string())?;
            let plan = inner
                .plan_leave(&group_id, &self_pk)
                .map_err(|e| e.to_string())?;
            Ok(match plan {
                haven_core::circle::LeavePlan::NonAdmin => LeavePlanFfi {
                    kind: LeavePlanKindFfi::NonAdmin,
                    successor_hex: None,
                },
                haven_core::circle::LeavePlan::AdminHandoff { successor } => LeavePlanFfi {
                    kind: LeavePlanKindFfi::AdminHandoff,
                    successor_hex: Some(successor.to_hex()),
                },
                haven_core::circle::LeavePlan::AdminDemote => LeavePlanFfi {
                    kind: LeavePlanKindFfi::AdminDemote,
                    successor_hex: None,
                },
                haven_core::circle::LeavePlan::Abandon => LeavePlanFfi {
                    kind: LeavePlanKindFfi::Abandon,
                    successor_hex: None,
                },
                haven_core::circle::LeavePlan::OrphanLocalOnly => LeavePlanFfi {
                    kind: LeavePlanKindFfi::OrphanLocalOnly,
                    successor_hex: None,
                },
            })
        })
        .await
    }

    /// Step 1 of admin handoff: propose promoting `successor_hex` to admin.
    /// Returns a pending commit — publish, then finalize or clear.
    pub async fn propose_admin_handoff(
        &self,
        mls_group_id: Vec<u8>,
        successor_hex: String,
    ) -> Result<UpdateGroupResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            let successor = nostr::PublicKey::from_hex(&successor_hex)
                .map_err(|_| "Invalid successor_hex".to_string())?;
            inner
                .propose_admin_handoff(&group_id, &successor)
                .map_err(|e| e.to_string())
        })
        .await?;
        convert_update_result(result)
    }

    /// Admin: replace this circle's group relay list (MIP-01) via a
    /// `GroupContextExtensions` commit.
    ///
    /// Returns a pending commit. Publish the returned evolution event to the
    /// **union of the circle's current relays and `new_relays`** (so a member
    /// only listening on a relay being removed still receives the commit),
    /// then call [`finalize_relay_update`](Self::finalize_relay_update) on ACK
    /// or [`clear_pending_commit`](Self::clear_pending_commit) on failure.
    /// `new_relays` MUST be non-empty, `wss://` (or the debug loopback test
    /// seam), credential-free, and at most 20 entries; admin authorization is
    /// enforced by MDK against live MLS state.
    pub async fn update_circle_relays(
        &self,
        mls_group_id: Vec<u8>,
        new_relays: Vec<String>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .update_circle_relays(&group_id, &new_relays)
                .map_err(|e| e.to_string())
        })
        .await?;
        convert_update_result(result)
    }

    /// Step 2 of admin handoff: demote self from admin.
    /// Returns a pending commit — publish, then finalize or clear.
    pub async fn propose_self_demote(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .propose_self_demote(&group_id)
                .map_err(|e| e.to_string())
        })
        .await?;
        convert_update_result(result)
    }

    /// Returns a `SelfRemove` proposal event. Publish it, then call
    /// `complete_leave` — no pending commit to finalize or clear.
    pub async fn propose_leave(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<UpdateGroupResultFfi, String> {
        let inner = self.inner.clone();
        let result = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner.propose_leave(&group_id).map_err(|e| e.to_string())
        })
        .await?;
        convert_update_result(result)
    }

    /// Removes the local circle row after a successful leave sequence, or
    /// for the `OrphanLocalOnly` plan.
    pub async fn complete_leave(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner.complete_leave(&group_id).map_err(|e| e.to_string())
        })
        .await
    }

    /// Wipes local state for the `Abandon` plan — sole-member cleanup with
    /// no MLS commit and no relay publish.
    pub async fn abandon_circle_local_only(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .abandon_circle_local_only(&group_id)
                .map_err(|e| e.to_string())
        })
        .await
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

    /// Adds members to an existing circle and gift-wraps their Welcomes.
    ///
    /// The add-time counterpart to [`create_circle`]: stages an MLS Add commit
    /// (kind 445, advances existing members on finalize) and gift-wraps the
    /// resulting per-member Welcome rumors (kind 444) for delivery, resolving
    /// each recipient's relays through the same fail-closed cascade.
    ///
    /// The caller owns the publish/finalize cycle: publish
    /// `evolution_event_json` to the circle's relays, finalize the pending
    /// commit on success (or clear it on failure), then publish each
    /// gift-wrapped Welcome only after a successful finalize.
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The admin's 32-byte Nostr secret key.
    /// * `mls_group_id` - The circle's MLS group ID.
    /// * `members` - Key packages and inbox/NIP-65 relays for the new members.
    /// * `creator_fallback_relays` - The admin's own inbox relays (kind 10050),
    ///   used as the third tier in the Welcome delivery cascade (member 10050 →
    ///   member 10002 → admin inbox → FAIL CLOSED). Pass an empty list if the
    ///   admin has no inbox relays; delivery then fails closed (no
    ///   public-default fallback) when tiers 1–2 are also empty.
    ///
    /// # Security
    ///
    /// The Welcome events are gift-wrapped per NIP-59, hiding the sender's
    /// identity behind a fresh ephemeral key. The secret bytes are zeroized.
    ///
    /// # Errors
    ///
    /// Returns an error if the secret bytes are invalid, a key package fails to
    /// parse, the caller is not an admin, or a member has no reachable Welcome
    /// relay (fail-closed).
    pub async fn add_members_to_circle(
        &self,
        identity_secret_bytes: Vec<u8>,
        mls_group_id: Vec<u8>,
        members: Vec<MemberKeyPackageFfi>,
        creator_fallback_relays: Vec<String>,
    ) -> Result<AddMembersResultFfi, String> {
        // Zeroize immediately so early-return paths don't leak secret bytes.
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        // Parse member key packages.
        let member_key_packages: Vec<haven_core::circle::MemberKeyPackage> = members
            .into_iter()
            .map(|m| {
                let key_package_event: nostr::Event = serde_json::from_str(&m.key_package_json)
                    .map_err(|e| format!("Invalid key package JSON: {e}"))?;
                Ok(haven_core::circle::MemberKeyPackage {
                    key_package_event,
                    inbox_relays: m.inbox_relays,
                    nip65_relays: m.nip65_relays,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;

        let group_id = GroupId::from_slice(&mls_group_id);

        // `add_members_with_welcomes` is genuinely async (giftwrap
        // construction awaits), so it stays on the current tokio worker.
        let result = self
            .inner
            .add_members_with_welcomes(
                &keys,
                &group_id,
                member_key_packages,
                &creator_fallback_relays,
            )
            .await
            .map_err(|e| e.to_string())?;

        let evolution_event_json = serde_json::to_string(&result.evolution_event)
            .map_err(|e| format!("Failed to serialize evolution event: {e}"))?;

        // Convert gift-wrapped welcome events to FFI.
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

        Ok(AddMembersResultFfi {
            evolution_event_json,
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
        notes: Option<String>,
    ) -> Result<ContactFfi, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .set_contact(&pubkey, display_name.as_deref(), notes.as_deref())
                .map(ContactFfi::from)
                .map_err(|e| e.to_string())
        })
        .await
    }

    // ==================== Avatar (profile pictures) ====================

    /// Processes and stores the user's own avatar from raw image bytes.
    ///
    /// EXIF/GPS stripping, downscaling, JPEG re-encoding, content hashing, and
    /// SQLCipher-encrypted storage all happen in `haven-core`. Returns metadata
    /// only — never the image bytes.
    pub async fn set_my_avatar(
        &self,
        own_pubkey: String,
        raw: Vec<u8>,
    ) -> Result<AvatarMetaFfi, String> {
        let inner = self.inner.clone();
        // Minimize the cleartext image lifetime on the FFI side: wipe on drop.
        let raw = zeroize::Zeroizing::new(raw);
        run_blocking(move || {
            inner
                .set_my_avatar(&own_pubkey, raw.as_slice())
                .map(AvatarMetaFfi::from)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Clears (removes) the user's own avatar.
    pub async fn clear_my_avatar(&self, own_pubkey: String) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .clear_my_avatar(&own_pubkey)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Returns the user's own avatar thumbnail bytes (hot path), or `None`.
    pub async fn get_my_avatar_thumbnail(
        &self,
        own_pubkey: String,
    ) -> Result<Option<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_my_avatar_thumbnail(&own_pubkey)
                .map(|opt| opt.map(|z| z.to_vec()))
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Returns the user's own full-resolution avatar bytes, or `None`.
    pub async fn get_my_avatar(&self, own_pubkey: String) -> Result<Option<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_my_avatar(&own_pubkey)
                .map(|opt| opt.map(|z| z.to_vec()))
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Builds the wire-ready kind-445 events that share the user's OWN avatar
    /// into a circle (M2). Returns an empty list if the user has no avatar.
    ///
    /// Each event reuses the existing kind-445 [`SignedEventFfi`] shape so the
    /// Dart relay layer publishes them with no new wire plumbing. On-change /
    /// anti-entropy SCHEDULING is the Dart layer's responsibility (M3); this
    /// just builds the events on demand. The outer NIP-40 expiration is sampled
    /// from the same jittered window location uses (DEC-4), so avatar events are
    /// byte- and tag-indistinguishable from location on the wire.
    pub async fn build_avatar_share_events(
        &self,
        mls_group_id: Vec<u8>,
        sender_pubkey_hex: String,
        update_interval_secs: u64,
    ) -> Result<Vec<SignedEventFfi>, String> {
        if !(60..=3600).contains(&update_interval_secs) {
            return Err(format!(
                "update_interval_secs out of range [60, 3600]: {update_interval_secs}"
            ));
        }
        let sender_pubkey = nostr::PublicKey::parse(&sender_pubkey_hex)
            .map_err(|e| format!("Invalid sender pubkey: {e}"))?;
        let inner = self.inner.clone();
        let events = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .build_avatar_share(&group_id, &sender_pubkey, update_interval_secs)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await?;

        Ok(events.iter().map(signed_event_to_ffi).collect())
    }

    /// Builds the wire-ready kind-445 tombstone that clears the user's avatar
    /// in a circle (a `haven-avatar-clear` with a bumped `version`).
    pub async fn build_avatar_clear_event(
        &self,
        mls_group_id: Vec<u8>,
        sender_pubkey_hex: String,
        update_interval_secs: u64,
    ) -> Result<SignedEventFfi, String> {
        if !(60..=3600).contains(&update_interval_secs) {
            return Err(format!(
                "update_interval_secs out of range [60, 3600]: {update_interval_secs}"
            ));
        }
        let sender_pubkey = nostr::PublicKey::parse(&sender_pubkey_hex)
            .map_err(|e| format!("Invalid sender pubkey: {e}"))?;
        let inner = self.inner.clone();
        let event = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            // Derive the tombstone version from the stored own-avatar version
            // (+1) so it strictly supersedes the avatar peers currently hold.
            // This reads the local store, so the Dart caller MUST publish the
            // clear BEFORE clearing the local avatar.
            let version = inner
                .own_avatar_version(&sender_pubkey_hex)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))?
                .map_or(1, |v| v + 1);
            inner
                .build_avatar_clear(&group_id, &sender_pubkey, version, update_interval_secs)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await?;
        Ok(signed_event_to_ffi(&event))
    }

    /// Decrypts an incoming kind-445 event and, if its inner kind-9 is an avatar
    /// payload, routes it through the reassembler and (on completion) stores it
    /// under the MLS-authenticated sender's pubkey.
    ///
    /// Non-avatar inners (location, group updates, unknown types) return an
    /// `accepted = false` / `complete = false` result with NO bytes — the
    /// caller's existing `decryptLocation` path still handles those. Returns NO
    /// image bytes ever; the UI re-fetches via `getAvatarThumbnail` /
    /// `getMemberAvatar` on `complete == true`.
    pub async fn ingest_incoming_avatar_message(
        &self,
        event_json: String,
    ) -> Result<AvatarIngestResultFfi, String> {
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .ingest_incoming_avatar_message(&event)
                .map(AvatarIngestResultFfi::from)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Returns a circle member's avatar thumbnail bytes (hot path), or `None`.
    pub async fn get_avatar_thumbnail(
        &self,
        mls_group_id: Vec<u8>,
        pubkey: String,
    ) -> Result<Option<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .get_member_avatar_thumbnail(&group_id, &pubkey)
                .map(|opt| opt.map(|z| z.to_vec()))
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Returns a circle member's full-resolution avatar bytes, or `None`.
    pub async fn get_member_avatar(
        &self,
        mls_group_id: Vec<u8>,
        pubkey: String,
    ) -> Result<Option<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .get_member_avatar(&group_id, &pubkey)
                .map(|opt| opt.map(|z| z.to_vec()))
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
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
    /// * `Ok(Some(invitation))` — a new pending invitation the caller must
    ///   accept or decline.
    /// * `Ok(None)` — the gift wrap has already been processed on a prior
    ///   poll cycle and should be silently skipped. This is the expected
    ///   outcome for NIP-59's 2-day lookback window repeatedly surfacing
    ///   the same wrapper events.
    /// * `Err(msg)` — a real failure (malformed event, MDK error, etc.).
    ///   The message is already sanitized via `redact_hex_sequences`.
    pub async fn process_gift_wrapped_invitation(
        &self,
        identity_secret_bytes: Vec<u8>,
        gift_wrap_event_json: String,
    ) -> Result<Option<InvitationFfi>, String> {
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
        match self
            .inner
            .process_gift_wrapped_invitation(&keys, &gift_wrap_event)
            .await
        {
            Ok(invitation) => Ok(Some(InvitationFfi::from(invitation))),
            // Idempotent skip: the poller has already processed this wrapper.
            // Flatten to `Ok(None)` so the Dart side never surfaces it as
            // a failure.
            Err(haven_core::circle::CircleError::AlreadyProcessed) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
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
    /// # Returns
    ///
    /// Same tri-state semantics as [`process_gift_wrapped_invitation`]:
    /// `Ok(Some(_))` for new invitations, `Ok(None)` for already-processed
    /// gift wraps (silent skip), `Err(_)` for real failures.
    ///
    /// [`process_gift_wrapped_invitation`]: Self::process_gift_wrapped_invitation
    pub async fn process_invitation(
        &self,
        wrapper_event_id: String,
        rumor_event_json: String,
        inviter_pubkey: String,
    ) -> Result<Option<InvitationFfi>, String> {
        // Parse the event ID
        let event_id = nostr::EventId::from_hex(&wrapper_event_id)
            .map_err(|e| format!("Invalid event ID: {e}"))?;

        // Parse the rumor event from JSON
        let rumor: nostr::UnsignedEvent = serde_json::from_str(&rumor_event_json)
            .map_err(|e| format!("Invalid rumor event JSON: {e}"))?;

        let inner = self.inner.clone();
        run_blocking(
            move || match inner.process_invitation(&event_id, &rumor, &inviter_pubkey) {
                Ok(invitation) => Ok(Some(InvitationFfi::from(invitation))),
                Err(haven_core::circle::CircleError::AlreadyProcessed) => Ok(None),
                Err(e) => Err(e.to_string()),
            },
        )
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

    /// Creates and signs the key package event pair (kinds 30443 and 443).
    ///
    /// Generates MLS key material once, then signs **both** the canonical
    /// kind 30443 (addressable) event and the legacy kind 443 twin from the
    /// same bundle (same `content` and `hash_ref`, only the tag set differs:
    /// the legacy twin omits the `d` tag).
    ///
    /// Publishing both is required during the MIP-00 transition window so
    /// that Marmot clients which still query kind 443 can discover this user.
    /// Mirrors the reference implementation (`whitenoise-rs`'s
    /// `publish_key_package_pair_to_relays`).
    ///
    /// # Arguments
    ///
    /// * `identity_secret_bytes` - The user's identity secret bytes (32 bytes)
    /// * `relays` - Relay URLs where the pair should be published
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

        // Parse tags from Vec<Vec<String>> into nostr::Tag for both kinds.
        let tags_30443 = parse_kp_tags(&bundle.tags_30443)?;
        let tags_443 = parse_kp_tags(&bundle.tags_443)?;

        // Sign both events from the same key material. The legacy twin
        // shares `content` and `hash_ref` with the canonical event; only
        // the tag set differs (no `d` tag for kind 443).
        let event_30443 =
            nostr::EventBuilder::new(nostr::Kind::Custom(30443), bundle.content.clone())
                .tags(tags_30443)
                .sign_with_keys(&keys)
                .map_err(|e| format!("Failed to sign kind 30443 key package event: {e}"))?;

        let event_443 = nostr::EventBuilder::new(nostr::Kind::Custom(443), bundle.content)
            .tags(tags_443)
            .sign_with_keys(&keys)
            .map_err(|e| format!("Failed to sign kind 443 key package event: {e}"))?;

        let event_json = serde_json::to_string(&event_30443)
            .map_err(|e| format!("Failed to serialize kind 30443 event: {e}"))?;
        let legacy_event_json = serde_json::to_string(&event_443)
            .map_err(|e| format!("Failed to serialize kind 443 event: {e}"))?;

        Ok(SignedKeyPackageEventFfi {
            event_json,
            legacy_event_json,
            relays: bundle.relays,
        })
    }

    // NOTE: `sign_relay_list_event` was removed.
    //
    // The privacy-toggle-aware flow goes through
    // [`Self::build_relay_list_publish`], which atomically reads the
    // user's `publish_*_relay_list` toggle, signs the event with the
    // correct kind (10050 or 10051), and resolves publish targets in a
    // single Rust dispatch. Exposing a parallel "sign without checking
    // toggle" method left a footgun for future contributors who could
    // accidentally publish a 10051 the user opted out of.
    //
    // If you need a kind 10051/10050 event, call
    // `build_relay_list_publish` and publish via `RelayManagerFfi`.

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
    ///
    /// # Concurrency
    ///
    /// Merges the pending commit into MDK's local group state — a non-atomic
    /// read-modify-write on the epoch. Callers **must not** invoke this
    /// concurrently with any other state-mutating call for the same
    /// `mls_group_id` (e.g., [`encrypt_location`], [`clear_pending_commit`],
    /// [`process_message`], or another `finalize_pending_commit`). The Dart
    /// side serialises evolution handling per circle, which satisfies this.
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

    /// Finalizes an admin relay update: merges the pending commit, then
    /// re-syncs the admin's own `circle.relays` from MDK so the admin
    /// converges on the new set immediately.
    ///
    /// Use this instead of [`finalize_pending_commit`](Self::finalize_pending_commit)
    /// for the relay-update flow (members converge via the receive path). Same
    /// concurrency contract as `finalize_pending_commit` — the Dart side
    /// serialises evolution handling per circle.
    pub async fn finalize_relay_update(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .finalize_relay_update(&group_id)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Clears a pending commit, rolling back the MLS group state.
    ///
    /// Call this when a relay publish fails after an operation that creates
    /// a pending commit. This prevents the group from being permanently
    /// blocked by a dangling pending commit.
    ///
    /// # Concurrency
    ///
    /// Drops the pending commit from MDK's local group state — a non-atomic
    /// read-modify-write on the epoch. Callers **must not** invoke this
    /// concurrently with any other state-mutating call for the same
    /// `mls_group_id` (e.g., [`encrypt_location`], [`finalize_pending_commit`],
    /// [`process_message`], or another `clear_pending_commit`). The Dart side
    /// serialises evolution handling per circle, which satisfies this.
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
    /// * `latitude` - GPS latitude (exact)
    /// * `longitude` - GPS longitude (exact)
    /// * `update_interval_secs` - Publish-cadence hint used to compute the
    ///   jittered NIP-40 `expiration` tag on the outer kind:445 wrapper.
    ///   Must be in `[60, 3600]`. The Dart call site normally passes
    ///   `kLocationPublishMaxInterval.inSeconds + 30` so the minimum
    ///   sampled TTL comfortably exceeds the maximum jittered publish delay
    ///   plus a network-propagation buffer — see `location.dart`. The
    ///   absolute expiration timestamp is sampled uniformly from
    ///   `[interval, 2 * interval]` seconds in the future.
    pub async fn encrypt_location(
        &self,
        mls_group_id: Vec<u8>,
        sender_pubkey_hex: String,
        latitude: f64,
        longitude: f64,
        display_name: Option<String>,
        update_interval_secs: u64,
    ) -> Result<EncryptedLocationFfi, String> {
        // Validate at the FFI boundary so a buggy Dart caller cannot produce
        // already-expired (0) or multi-day TTLs. The range mirrors
        // `haven_core::location::ttl::{MIN,MAX}_UPDATE_INTERVAL_SECS`
        // (60..=3600) so callers get an explicit error instead of a silent
        // clamp-up inside the core.
        if !(60..=3600).contains(&update_interval_secs) {
            return Err(format!(
                "update_interval_secs out of range [60, 3600]: {update_interval_secs}"
            ));
        }
        let sender_pubkey = nostr::PublicKey::parse(&sender_pubkey_hex)
            .map_err(|e| format!("Invalid sender pubkey: {e}"))?;
        let location = haven_core::location::LocationMessage::new(latitude, longitude)
            .with_display_name(display_name);

        let inner = self.inner.clone();
        let (event, nostr_group_id, relays) = run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner
                .encrypt_location(&group_id, &sender_pubkey, &location, update_interval_secs)
                .map_err(|e| e.to_string())
        })
        .await?;

        let event_json =
            serde_json::to_string(&event).map_err(|e| format!("Failed to serialize event: {e}"))?;

        // Event id prefix for correlating publish → fetch → decrypt across
        // the two devices. Public on relays, so no privacy cost.
        let evt_prefix: String = event.id.to_hex().chars().take(8).collect();
        log::debug!(
            "[FFI encrypt] evt={evt_prefix} → kind:445 ready (relays={})",
            relays.len()
        );

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
    ///   member list.
    ///   When `evolution_event_json` is `Some`, MDK auto-committed a peer's
    ///   `SelfRemove` proposal and staged a pending commit. The caller MUST
    ///   publish the event to the circle's relays and then call
    ///   `finalizePendingCommit` (or `clearPendingCommit` on publish failure)
    ///   so the local MLS epoch advances.
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

        // Event id prefix for correlating diagnostic logs across publish /
        // fetch / decrypt. Nostr event ids are public on relays so the
        // prefix carries no privacy cost.
        let evt_prefix: String = event.id.to_hex().chars().take(8).collect();

        let inner = self.inner.clone();
        // Defense-in-depth: the core `decrypt_location` already redacts its
        // error strings, but re-redact at the FFI boundary so the invariant is
        // local here too (matches the sibling FFI methods in this file).
        let result = run_blocking(move || {
            inner
                .decrypt_location(&event)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await?;

        match result {
            haven_core::nostr::mls::types::LocationMessageResult::Location {
                sender_pubkey,
                content,
                ..
            } => {
                let location: haven_core::location::LocationMessage =
                    serde_json::from_str(&content)
                        .map_err(|e| format!("Failed to parse location: {e}"))?;
                // Normalize to lowercase so Dart-side self-compare against
                // the cached own pubkey is case-insensitive by construction.
                let sender_pubkey = normalize_pubkey_hex(&sender_pubkey);
                let sender_prefix: String = sender_pubkey.chars().take(8).collect();
                log::debug!("[FFI decrypt] evt={evt_prefix} → location (sender={sender_prefix})");
                Ok(Some(DecryptResultFfi {
                    location: Some(DecryptedLocationFfi {
                        sender_pubkey,
                        latitude: location.latitude,
                        longitude: location.longitude,
                        geohash: location.geohash,
                        timestamp: location.timestamp.timestamp(),
                        expires_at: location.expires_at.timestamp(),
                        display_name: haven_core::location::types::sanitize_display_name(
                            location.display_name,
                        ),
                    }),
                    group_updated: false,
                    evolution_event_json: None,
                    evolution_mls_group_id: None,
                }))
            }
            haven_core::nostr::mls::types::LocationMessageResult::GroupUpdate {
                group_id,
                evolution_event,
            } => {
                // `evolution_event` is `Some` only when MDK auto-commits a
                // peer's SelfRemove proposal. Serialize it here so the
                // Flutter layer can publish it without touching MDK types.
                let evolution_event_json = match evolution_event {
                    Some(event) => Some(
                        serde_json::to_string(&event)
                            .map_err(|e| format!("Failed to serialize evolution event: {e}"))?,
                    ),
                    None => None,
                };
                let evolution_mls_group_id = evolution_event_json
                    .as_ref()
                    .map(|_| group_id.as_slice().to_vec());
                log::debug!(
                    "[FFI decrypt] evt={evt_prefix} → group_update (auto_commit={})",
                    evolution_event_json.is_some()
                );
                Ok(Some(DecryptResultFfi {
                    location: None,
                    group_updated: true,
                    evolution_event_json,
                    evolution_mls_group_id,
                }))
            }
            haven_core::nostr::mls::types::LocationMessageResult::Unprocessable {
                reason, ..
            } => {
                // Surface the MDK reason (already redacted by haven-core's
                // `to_location_result` / `redact_hex_sequences`) so we can
                // distinguish epoch mismatches, malformed payloads, and
                // expiration-grace drops from `PreviouslyFailed`.
                log::debug!("[FFI decrypt] evt={evt_prefix} → unprocessable ({reason})");
                Ok(None)
            }
            haven_core::nostr::mls::types::LocationMessageResult::PreviouslyFailed => {
                log::debug!("[FFI decrypt] evt={evt_prefix} → previously_failed");
                Ok(None)
            }
        }
    }

    // ==================== Last-Known Location Cache ====================

    /// Persists a last-known location row.
    ///
    /// Input is validated at the FFI boundary; the core manager is the
    /// authoritative enforcement point for `purge_after` derivation. The
    /// `purge_after` value supplied by the caller is advisory only — the
    /// core recomputes it as `timestamp + LOCATION_RETENTION_SECS`.
    pub async fn upsert_last_known_location(
        &self,
        location: LastKnownLocationFfi,
    ) -> Result<(), String> {
        let ngid = parse_nostr_group_id(&location.nostr_group_id)?;
        validate_pubkey_hex(&location.sender_pubkey, "sender_pubkey")?;
        let sender_pubkey = normalize_pubkey_hex(&location.sender_pubkey);

        let core = haven_core::circle::LastKnownLocation {
            nostr_group_id: ngid,
            sender_pubkey,
            latitude: location.latitude,
            longitude: location.longitude,
            geohash: location.geohash,
            display_name: location.display_name,
            timestamp: location.timestamp,
            expires_at: location.expires_at,
            // Core re-derives this from timestamp + LOCATION_RETENTION_SECS;
            // caller value is ignored.
            purge_after: location.purge_after,
            updated_at: location.updated_at,
        };

        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .upsert_last_known_location(&core)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
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
                display_name: loc.display_name,
                timestamp: loc.timestamp,
                expires_at: loc.expires_at,
                purge_after: loc.purge_after,
                updated_at: loc.updated_at,
            })
            .collect())
    }

    /// Removes the last-known location for a single sender in a circle.
    ///
    /// Called when a member is removed from the circle.
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

    // ==================== Relay preferences (kind 10050 / 10051) ====================

    /// Seeds the user's relay lists with the default relay list returned by
    /// [`haven_core::circle::default_relays`] on first launch.
    ///
    /// Idempotent: short-circuits via the `relay_prefs_seeded_v1` sentinel
    /// in `user_settings`. Crucially, the sentinel is the signal — never
    /// row presence in `user_relays`. A user who removes a default relay
    /// must not have it re-added by the next defensive seed.
    ///
    /// # Returns
    ///
    /// `true` if seeding actually wrote rows; `false` if the sentinel was
    /// already set.
    pub async fn seed_relay_defaults_if_unseeded(&self) -> Result<bool, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .seed_relay_defaults_if_unseeded()
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Returns the user's relays for one category, ordered by insertion time.
    pub async fn list_user_relays(&self, relay_type: RelayTypeFfi) -> Result<Vec<String>, String> {
        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        run_blocking(move || inner.list_user_relays(core_type).map_err(|e| e.to_string())).await
    }

    /// Adds a relay to one category (idempotent).
    ///
    /// The URL is normalized via `nostr::RelayUrl::parse`; duplicates are
    /// silent no-ops. `ws://` and credential-bearing URLs are rejected.
    pub async fn add_user_relay(
        &self,
        url: String,
        relay_type: RelayTypeFfi,
    ) -> Result<(), String> {
        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .add_user_relay(&url, core_type)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Removes a relay from one category.
    ///
    /// Returns `true` when a row was removed, `false` when the URL was not
    /// in the user's list. Refuses to delete the last relay in a category
    /// (returns `Err` so the UI can show "you need at least one relay").
    pub async fn remove_user_relay(
        &self,
        url: String,
        relay_type: RelayTypeFfi,
    ) -> Result<bool, String> {
        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .remove_user_relay(&url, core_type)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Restores defaults for a category **non-destructively**.
    ///
    /// Adds any missing default relays via `INSERT OR IGNORE`. Existing
    /// user-added custom relays are preserved. Use
    /// [`Self::wipe_and_reset_defaults_for`] for the destructive variant.
    pub async fn restore_defaults_for(&self, relay_type: RelayTypeFfi) -> Result<(), String> {
        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .restore_relay_defaults_for(core_type)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Destructively resets a category to exactly the default relay list
    /// returned by [`haven_core::circle::default_relays`].
    ///
    /// Wipes all rows for the category and re-inserts defaults in one
    /// transaction. The caller MUST gate this behind a confirmation
    /// dialog; the function name is deliberately verbose.
    pub async fn wipe_and_reset_defaults_for(
        &self,
        relay_type: RelayTypeFfi,
    ) -> Result<(), String> {
        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .wipe_and_reset_relay_defaults_for(core_type)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Returns whether this user wants to publish their relay list for the
    /// given category. Defaults to `true` when never set.
    pub async fn get_publish_relay_list(&self, relay_type: RelayTypeFfi) -> Result<bool, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            match relay_type {
                RelayTypeFfi::Inbox => inner.get_publish_inbox_relay_list(),
                RelayTypeFfi::KeyPackage => inner.get_publish_kp_relay_list(),
            }
            .map_err(|e| e.to_string())
        })
        .await
    }

    /// Sets whether this user wants to publish their relay list for the
    /// given category.
    pub async fn set_publish_relay_list(
        &self,
        relay_type: RelayTypeFfi,
        value: bool,
    ) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            match relay_type {
                RelayTypeFfi::Inbox => inner.set_publish_inbox_relay_list(value),
                RelayTypeFfi::KeyPackage => inner.set_publish_kp_relay_list(value),
            }
            .map_err(|e| e.to_string())
        })
        .await
    }

    /// Returns the deduplicated publish targets for `relay_type` — the
    /// user's own configured relays and nothing else.
    ///
    /// Two-plane model: this is exactly the user's configured list (no
    /// force-union with public defaults), so a private relay never leaks.
    /// Exposed for the relay-status UI. The publish flow uses the same
    /// computation internally; do NOT use this method to compute publish
    /// targets in Dart — call [`Self::build_relay_list_publish`] instead.
    pub async fn relay_publish_targets(
        &self,
        relay_type: RelayTypeFfi,
    ) -> Result<Vec<String>, String> {
        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        run_blocking(move || {
            let user = inner
                .list_user_relays(core_type)
                .map_err(|e| e.to_string())?;
            Ok::<Vec<String>, String>(haven_core::relay::dedup_relay_targets(&user))
        })
        .await
    }

    /// Atomically gates on the toggle, signs a kind 10050 / 10051 event,
    /// and resolves the publish targets.
    ///
    /// This is the **only** path through which Dart should publish a relay
    /// list: it ensures the toggle check, signing, and target resolution
    /// happen as one operation. When the toggle is off, returns
    /// `suppressed=true` and no event — Dart MUST NOT publish anything in
    /// that case.
    ///
    /// On success, after publishing the returned event JSON to the
    /// returned `targets`, Dart should call
    /// [`Self::record_published_relay_list`] so the unpublish path can
    /// later issue a NIP-09 deletion referencing the event id.
    pub async fn build_relay_list_publish(
        &self,
        identity_secret_bytes: Vec<u8>,
        relay_type: RelayTypeFfi,
    ) -> Result<BuiltRelayListEventFfi, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);

        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();

        // Read toggle + list + compute targets all under one blocking dispatch.
        let prep: (bool, Vec<String>, Vec<String>) = run_blocking(move || {
            let publish = match core_type {
                haven_core::circle::RelayType::Inbox => inner.get_publish_inbox_relay_list(),
                haven_core::circle::RelayType::KeyPackage => inner.get_publish_kp_relay_list(),
            }
            .map_err(|e| e.to_string())?;
            if !publish {
                return Ok::<(bool, Vec<String>, Vec<String>), String>((
                    false,
                    Vec::new(),
                    Vec::new(),
                ));
            }
            let user = inner
                .list_user_relays(core_type)
                .map_err(|e| e.to_string())?;
            let targets = haven_core::relay::dedup_relay_targets(&user);
            Ok((true, user, targets))
        })
        .await?;

        let (publish_enabled, user_list, targets) = prep;
        if !publish_enabled {
            return Ok(BuiltRelayListEventFfi {
                event_json: None,
                event_id_hex: None,
                targets: Vec::new(),
                kind: None,
                created_at_secs: None,
                suppressed: true,
            });
        }

        let event = haven_core::relay::build_relay_list_event(&keys, core_type, &user_list, None)
            .map_err(|e| format!("Failed to build relay list event: {e}"))?;
        let event_json = serde_json::to_string(&event)
            .map_err(|e| format!("Failed to serialize relay list event: {e}"))?;
        let event_id_hex = event.id.to_hex();
        let kind_u16 = event.kind.as_u16();
        // Capture the signed event's `created_at` so the caller can pass
        // it to `record_published_relay_list`. Recording the *signed*
        // value (rather than re-fetching `SystemTime::now()` later) keeps
        // the unpublish-side `max(now, last_published_at + 1)` arithmetic
        // anchored to what relays actually saw on the wire.
        let created_at_secs = i64::try_from(event.created_at.as_secs()).ok();

        Ok(BuiltRelayListEventFfi {
            event_json: Some(event_json),
            event_id_hex: Some(event_id_hex),
            targets,
            kind: Some(kind_u16),
            created_at_secs,
            suppressed: false,
        })
    }

    /// Records a successful publication so the unpublish path can issue a
    /// NIP-09 deletion later. Pass the `event_id_hex`, `kind`, and
    /// `published_at_secs` returned in
    /// [`BuiltRelayListEventFfi`] after a successful relay publish.
    ///
    /// `published_at_secs` MUST be the `created_at` of the signed event
    /// (not a freshly-fetched local timestamp). If a Dart caller loses
    /// the value (older bindings) it may pass a current-time fallback,
    /// but the unpublish path's clock-skew defense is then weaker.
    pub async fn record_published_relay_list(
        &self,
        identity_pubkey_hex: String,
        kind: u16,
        event_id_hex: String,
        published_at_secs: i64,
    ) -> Result<(), String> {
        let pubkey = nostr::PublicKey::parse(&identity_pubkey_hex)
            .map_err(|e| format!("Invalid pubkey: {e}"))?;
        let event_id = nostr::EventId::from_hex(&event_id_hex)
            .map_err(|e| format!("Invalid event id: {e}"))?;
        let inner = self.inner.clone();
        let now = published_at_secs;
        run_blocking(move || {
            inner
                .record_published_event(kind, "", &event_id, &pubkey, now)
                .map_err(|e| e.to_string())
        })
        .await
    }

    /// Builds the events needed to unpublish a relay list category.
    ///
    /// Produces (1) an empty-replacement event with `created_at` chosen to
    /// supersede the previous publication via Nostr's replaceable-event
    /// semantics, and (2) a best-effort NIP-09 (kind 5) deletion if a
    /// prior publication is on record.
    ///
    /// Dart should publish both events to the returned `targets` and then
    /// also flip the toggle off via `set_publish_relay_list`. This method
    /// itself does not change the toggle.
    pub async fn build_unpublish_relay_list(
        &self,
        identity_secret_bytes: Vec<u8>,
        relay_type: RelayTypeFfi,
    ) -> Result<BuiltUnpublishFfi, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);
        let pubkey = keys.public_key();

        let core_type = haven_core::circle::RelayType::from(relay_type);
        let inner = self.inner.clone();
        let kind_u16 = core_type.to_kind().as_u16();

        // Look up prior publication and resolve targets atomically.
        let lookup: (
            Option<haven_core::circle::PublishedEventRecord>,
            Vec<String>,
        ) = run_blocking(move || {
            let user = inner
                .list_user_relays(core_type)
                .map_err(|e| e.to_string())?;
            let last = inner
                .last_published_event(kind_u16, "", &pubkey)
                .map_err(|e| e.to_string())?;
            Ok::<
                (
                    Option<haven_core::circle::PublishedEventRecord>,
                    Vec<String>,
                ),
                String,
            >((last, user))
        })
        .await?;
        let (last_event, user_list) = lookup;

        let targets = haven_core::relay::dedup_relay_targets(&user_list);

        let last_published_at = last_event.as_ref().map(|r| r.published_at);
        let replacement =
            haven_core::relay::build_unpublish_event(&keys, core_type, last_published_at)
                .map_err(|e| format!("Failed to build replacement: {e}"))?;
        let replacement_json = serde_json::to_string(&replacement)
            .map_err(|e| format!("Failed to serialize replacement: {e}"))?;

        let deletion_json = match last_event {
            Some(record) => {
                let deletion = haven_core::relay::build_nip09_deletion(
                    &keys,
                    record.event_id,
                    core_type.to_kind(),
                )
                .map_err(|e| format!("Failed to build deletion: {e}"))?;
                Some(
                    serde_json::to_string(&deletion)
                        .map_err(|e| format!("Failed to serialize deletion: {e}"))?,
                )
            }
            None => None,
        };

        Ok(BuiltUnpublishFfi {
            replacement_event_json: Some(replacement_json),
            deletion_event_json: deletion_json,
            targets,
            suppressed: false,
        })
    }

    /// Builds a best-effort NIP-09 deletion to scrub a removed relay's stale
    /// copy of the user's relay list.
    ///
    /// Two-plane removal hygiene: when the user removes relay(s) from a list
    /// type, the new (smaller) list is republished to the *kept* relays, but
    /// the *dropped* relays still hold the previous event — which may name a
    /// private relay the user is now trying to keep private. This builds a
    /// kind-5 deletion (referencing the last published event id) to publish
    /// to `dropped_relays` so cooperative relays drop that stale copy.
    ///
    /// No empty-replacement is produced: a replaceable empty event with a
    /// higher `created_at` than the corrected list could make indexers treat
    /// the user as having no relays (undiscoverable). The corrected list is
    /// reasserted globally by the kept-relay republish; this deletion only
    /// cleans up direct queriers of the dropped relays.
    ///
    /// Best-effort: relays that do not honor NIP-09 may retain the old event.
    /// MUST be called BEFORE republishing the new list, so the looked-up
    /// last-published event is the stale one being scrubbed. Returns
    /// `suppressed=true` with no event when nothing was ever published for
    /// this kind (the dropped relays never received our list).
    pub async fn build_relay_removal_scrub(
        &self,
        identity_secret_bytes: Vec<u8>,
        relay_type: RelayTypeFfi,
        dropped_relays: Vec<String>,
    ) -> Result<BuiltUnpublishFfi, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
            .map_err(|e| format!("Invalid secret key: {e}"))?;
        let keys = nostr::Keys::new(secret_key);
        let pubkey = keys.public_key();

        if dropped_relays.is_empty() {
            return Ok(BuiltUnpublishFfi {
                replacement_event_json: None,
                deletion_event_json: None,
                targets: Vec::new(),
                suppressed: true,
            });
        }

        let core_type = haven_core::circle::RelayType::from(relay_type);
        let kind_u16 = core_type.to_kind().as_u16();
        let inner = self.inner.clone();

        let last = run_blocking(move || {
            inner
                .last_published_event(kind_u16, "", &pubkey)
                .map_err(|e| e.to_string())
        })
        .await?;

        let Some(record) = last else {
            // Nothing was ever published for this kind, so the dropped relays
            // never received our list — nothing to scrub.
            return Ok(BuiltUnpublishFfi {
                replacement_event_json: None,
                deletion_event_json: None,
                targets: Vec::new(),
                suppressed: true,
            });
        };

        let deletion =
            haven_core::relay::build_nip09_deletion(&keys, record.event_id, core_type.to_kind())
                .map_err(|e| format!("Failed to build deletion: {e}"))?;
        let deletion_json = serde_json::to_string(&deletion)
            .map_err(|e| format!("Failed to serialize deletion: {e}"))?;

        Ok(BuiltUnpublishFfi {
            replacement_event_json: None,
            deletion_event_json: Some(deletion_json),
            targets: dropped_relays,
            suppressed: false,
        })
    }

    /// Returns this manager's current MLS epoch for a group (debug-only).
    ///
    /// Each E2E peer (the production UI plus the synthetic FFI peers) owns its
    /// own MDK instance, so the epoch must be read per-manager — hence a method
    /// on [`CircleManagerFfi`] rather than a free function. Used to assert
    /// real key rotation: after an Add/remove/self-update commit is finalized
    /// (or a peer processes one), the epoch MUST advance by exactly 1. The
    /// epoch counter is not secret; this seam is compiled out of release
    /// builds (see the sibling stub).
    ///
    /// # Errors
    ///
    /// Returns an error if the group does not exist or the MDK query fails.
    #[cfg(debug_assertions)]
    pub async fn group_epoch_for_test(&self, mls_group_id: Vec<u8>) -> Result<u64, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner.group_epoch(&group_id).map_err(|e| e.to_string())
        })
        .await
    }

    /// Release-build stub for [`group_epoch_for_test`](Self::group_epoch_for_test).
    ///
    /// The `CircleManager::group_epoch` accessor is gated on debug builds, so
    /// this seam fails closed in release builds.
    ///
    /// # Errors
    ///
    /// Always returns an error.
    #[cfg(not(debug_assertions))]
    pub async fn group_epoch_for_test(&self, _mls_group_id: Vec<u8>) -> Result<u64, String> {
        Err("group_epoch_for_test is disabled in release builds".to_string())
    }
}

// ==================== Top-level sync helpers ====================

/// Returns the canonical default relay list shared by Rust and Dart.
///
/// Single source of truth for [`haven_core::circle::default_relays`].
/// Replaces the previous Dart `defaultRelays` constant — eliminates the
/// "two constants must agree" drift class. In debug builds this honors any
/// test override installed via [`set_default_relays_for_test`].
#[frb(sync)]
#[must_use]
pub fn default_relays() -> Vec<String> {
    haven_core::circle::default_relays()
}

/// Overrides the default relay list for E2E tests.
///
/// Forwards to [`haven_core::circle::set_default_relays_for_test`] (debug
/// builds) or returns an error in release builds. Intended to be called
/// from a Patrol scenario's `setUpAll` before any service creation so every
/// Rust call site that touches the default relay list redirects to the
/// local strfry.
///
/// # Errors
///
/// * Returns an error if the override has already been installed (the
///   underlying `OnceLock` is install-once per process).
/// * Returns an error if `relays` is empty.
/// * In release builds this function is unreachable; the sibling stub
///   always returns an error.
#[cfg(debug_assertions)]
#[frb(sync)]
pub fn set_default_relays_for_test(relays: Vec<String>) -> Result<(), String> {
    haven_core::circle::set_default_relays_for_test(relays)
}

/// Release-build stub for [`set_default_relays_for_test`].
///
/// Returns an error so release callers fail closed. Gating the FFI wrapper
/// itself (not just the haven-core function it forwards to) keeps the
/// test-affordance symbol out of the release `.so`'s exported function
/// table, so a `strings` / `nm` walk on the shipping binary can't fingerprint
/// it as having been built with test hooks. Mirrors the pattern used by
/// [`use_in_memory_keyring_for_test`].
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
#[frb(sync)]
pub fn set_default_relays_for_test(_relays: Vec<String>) -> Result<(), String> {
    Err("set_default_relays_for_test is disabled in release builds".to_string())
}

/// Returns the read-only discovery-plane relay list (public indexers).
///
/// Single source of truth for
/// [`haven_core::relay::discovery_relays`]. These relays are queried ONLY to
/// discover *other* users' metadata/relay lists by bare pubkey; they are
/// NEVER a publish or gift-wrap-poll target. Dart's `discoveryRelays` getter
/// is backed by this so a private relay is never sent to a public indexer.
/// In debug builds this honors any override installed via
/// [`set_discovery_relays_for_test`].
#[frb(sync)]
#[must_use]
pub fn discovery_relays() -> Vec<String> {
    haven_core::relay::discovery_relays()
}

/// Overrides the discovery relay list for E2E tests.
///
/// Forwards to [`haven_core::relay::set_discovery_relays_for_test`] (debug
/// builds) or returns an error in release builds. Intended to be called from
/// a Patrol scenario's `setUpAll` (alongside [`set_default_relays_for_test`])
/// so every Rust discovery read redirects to the local strfry and the suite
/// stays hermetic.
///
/// # Errors
///
/// * Returns an error if the override has already been installed (the
///   underlying `OnceLock` is install-once per process).
/// * Returns an error if `relays` is empty.
/// * In release builds this function is unreachable; the sibling stub always
///   returns an error.
#[cfg(debug_assertions)]
#[frb(sync)]
pub fn set_discovery_relays_for_test(relays: Vec<String>) -> Result<(), String> {
    haven_core::relay::set_discovery_relays_for_test(relays)
}

/// Release-build stub for [`set_discovery_relays_for_test`].
///
/// Returns an error so release callers fail closed, and keeps the
/// test-affordance symbol out of the shipping binary's exported function
/// table. Mirrors [`set_default_relays_for_test`]'s release stub.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
#[frb(sync)]
pub fn set_discovery_relays_for_test(_relays: Vec<String>) -> Result<(), String> {
    Err("set_discovery_relays_for_test is disabled in release builds".to_string())
}

/// Opt in to plaintext `ws://` URLs targeting loopback / emulator-host
/// aliases for hermetic E2E tests.
///
/// Forwards to [`haven_core::relay::allow_ws_loopback_for_test`] (debug
/// builds) or returns an error in release builds. Without this opt-in the
/// Rust relay validator hard-rejects every `ws://` URL, blocking the
/// scenario harness from pointing at strfry on `ws://10.0.2.2:7777`
/// (Android emulator) or `ws://localhost:7777` (direct host). Intended to
/// be called from `ScenarioHarness.bootstrap` BEFORE
/// [`set_default_relays_for_test`].
///
/// Even with the opt-in installed, only loopback / emulator-host aliases
/// are accepted; LAN and public hosts continue to be rejected. The two
/// checks are AND-ed so a misconfigured
/// `--dart-define=HAVEN_E2E_RELAY=ws://relay.example/` cannot leak.
///
/// # Errors
///
/// * Returns an error if the opt-in has already been installed in this
///   process (`OnceLock` install-once semantics).
/// * In release builds this function is unreachable; the sibling stub
///   always returns an error.
#[cfg(debug_assertions)]
#[frb(sync)]
pub fn allow_ws_loopback_for_test() -> Result<(), String> {
    haven_core::relay::allow_ws_loopback_for_test()
}

/// Release-build stub for [`allow_ws_loopback_for_test`]. See
/// [`set_default_relays_for_test`] for the binary-fingerprint rationale
/// behind gating the FFI wrapper itself in addition to the haven-core
/// function it forwards to.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
#[frb(sync)]
pub fn allow_ws_loopback_for_test() -> Result<(), String> {
    Err("allow_ws_loopback_for_test is disabled in release builds".to_string())
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

/// Per-relay outcome of a gift-wrap fetch (FFI-friendly).
///
/// `responded` is true when the relay completed the WebSocket handshake (it
/// answered), even if it returned no events. A relay that answered with zero
/// events is `responded == true` with an empty `events` list — distinct from
/// an unreachable relay (`responded == false`). `events` holds the gift-wrap
/// event JSON strings fetched from this relay.
#[derive(Debug, Clone)]
pub struct RelayGiftWrapFetchFfi {
    /// The relay URL that was queried.
    pub relay_url: String,
    /// Whether the relay answered (completed the WebSocket handshake).
    pub responded: bool,
    /// Gift-wrap event JSON strings fetched from this relay.
    pub events: Vec<String>,
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

    /// Removes a single relay from the persistent connection pool by URL
    /// and tears down its WebSocket.
    ///
    /// Used by the relay-preferences UI when the user explicitly removes
    /// a relay so we do not keep leaking metadata via an idle WebSocket
    /// to a relay the user no longer trusts. Routed through the same
    /// `nostr_sdk::Client` that powers `publish_event`, `fetch_events`,
    /// and `subscribe` so removal is symmetric with addition.
    ///
    /// Returns `Ok(())` even when the relay was never connected — the
    /// caller's intent ("stop talking to this relay") is satisfied either
    /// way.
    pub async fn disconnect_relay(&self, url: String) -> Result<(), String> {
        self.inner
            .remove_relay(&url)
            .await
            .map_err(|e| e.to_string())
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

    /// Fetches a user's `KeyPackage` with their relay lists.
    ///
    /// Concurrently fetches three replaceable relay-list events:
    /// - kind 10051 for `KeyPackage` discovery
    /// - kind 10050 for Welcome delivery (NIP-17 inbox)
    /// - kind 10002 for Welcome delivery fallback (NIP-65)
    ///
    /// Then runs the shared `KeyPackage` discovery cascade
    /// (`fetch_keypackage_with_cascade`): 10051 → NIP-65 → defaults.
    ///
    /// Each relay-list fetch is tolerated independently: a transient failure
    /// on one list does not abort the whole call. The returned
    /// `MemberKeyPackageFfi` carries the 10050 and 10002 lists so the caller
    /// can run the Welcome delivery cascade (10050 → 10002 → defaults).
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub format)
    ///
    /// # Returns
    ///
    /// A `MemberKeyPackageFfi` with the key package, inbox relays,
    /// and NIP-65 relays, or `None` if no `KeyPackage` was found.
    pub async fn fetch_member_keypackage(
        &self,
        pubkey: String,
    ) -> Result<Option<MemberKeyPackageFfi>, String> {
        // Fetch all three relay lists concurrently. Each arm is tolerated
        // independently: a transient failure on one list is logged and treated
        // as an empty list so the cascade can still fall through to later
        // tiers rather than aborting the whole operation.
        let (keypackage_result, inbox_result, nip65_result) = tokio::join!(
            self.inner.fetch_keypackage_relays(&pubkey),
            self.inner.fetch_inbox_relays(&pubkey),
            self.inner.fetch_nip65_relays(&pubkey),
        );

        let keypackage_relays = keypackage_result.unwrap_or_else(|e| {
            log::debug!(
                "[fetch_member_keypackage] kind 10051 fetch failed: {}",
                haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
            );
            Vec::new()
        });
        let inbox_relays = inbox_result.unwrap_or_else(|e| {
            log::debug!(
                "[fetch_member_keypackage] kind 10050 fetch failed: {}",
                haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
            );
            Vec::new()
        });
        let nip65_relays = nip65_result.unwrap_or_else(|e| {
            log::debug!(
                "[fetch_member_keypackage] kind 10002 fetch failed: {}",
                haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
            );
            Vec::new()
        });

        // Delegate the KeyPackage discovery cascade to the core helper so the
        // 10051 → NIP-65 → defaults logic lives in exactly one place.
        let event = self
            .inner
            .fetch_keypackage_with_cascade(&pubkey, &keypackage_relays, &nip65_relays)
            .await
            .map_err(|e| e.to_string())?;

        match event {
            Some(e) => {
                let key_package_json = serde_json::to_string(&e)
                    .map_err(|e| format!("Failed to serialize key package event: {e}"))?;
                Ok(Some(MemberKeyPackageFfi {
                    key_package_json,
                    inbox_relays,
                    nip65_relays,
                }))
            }
            None => Ok(None),
        }
    }

    /// Fetches a user's NIP-65 relay list (kind 10002).
    ///
    /// Returns the relay URLs from the user's general-purpose relay list.
    /// Used as a fallback when inbox relays (kind 10050) are not available.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub format)
    ///
    /// # Returns
    ///
    /// List of relay URLs from "r" tags, or empty if no relay list is published.
    pub async fn fetch_nip65_relays(&self, pubkey: String) -> Result<Vec<String>, String> {
        self.inner
            .fetch_nip65_relays(&pubkey)
            .await
            .map_err(|e| e.to_string())
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

    /// Fetches gift-wrapped events (kind 1059) per relay, reporting which
    /// relays answered.
    ///
    /// Like [`fetch_gift_wraps`](Self::fetch_gift_wraps), but instead of one
    /// merged list it queries each relay independently and returns a per-relay
    /// outcome: whether the relay answered (`responded`) and the events it
    /// returned. This lets the caller show an accurate "N of M inboxes
    /// answered" tally. A relay that answers with zero events is
    /// `responded == true` with an empty `events` list — distinct from an
    /// unreachable relay (`responded == false`).
    ///
    /// # Arguments
    ///
    /// * `recipient_pubkey` - The recipient's public key (hex or npub format)
    /// * `relays` - Relay URLs to query, each independently
    /// * `since` - Optional Unix timestamp (seconds); only events after this time
    ///
    /// # Returns
    ///
    /// One [`RelayGiftWrapFetchFfi`] per relay, in input order.
    pub async fn fetch_gift_wraps_per_relay(
        &self,
        recipient_pubkey: String,
        relays: Vec<String>,
        since: Option<i64>,
    ) -> Result<Vec<RelayGiftWrapFetchFfi>, String> {
        let pk = nostr::PublicKey::parse(&recipient_pubkey)
            .map_err(|e| format!("Invalid recipient pubkey: {e}"))?;

        // The per-relay count is shown to the user as exact, so the cap is a
        // generous flood-guard rather than a paging limit: a real inbox holds
        // far fewer than this many gift wraps in the 2-day lookback window, so
        // the headline "N new invitations" is not silently truncated.
        let mut filter = nostr::Filter::new()
            .kind(nostr::Kind::GiftWrap)
            .pubkey(pk)
            .limit(1000);

        if let Some(ts) = since {
            let secs = u64::try_from(ts).map_err(|_| "since timestamp must be non-negative")?;
            filter = filter.since(nostr::Timestamp::from(secs));
        }

        let outcomes = self
            .inner
            .fetch_events_per_relay(filter, &relays)
            .await
            .map_err(|e| e.to_string())?;

        outcomes
            .into_iter()
            .map(|o| {
                let events = o
                    .events
                    .into_iter()
                    .map(|e| {
                        serde_json::to_string(&e)
                            .map_err(|err| format!("Failed to serialize event: {err}"))
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(RelayGiftWrapFetchFfi {
                    relay_url: o.relay_url,
                    responded: o.responded,
                    events,
                })
            })
            .collect::<Result<Vec<_>, String>>()
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

    /// Verifies that `DecryptResultFfi`'s `Debug` impl never emits the raw
    /// evolution event JSON (which embeds the MLS group ID in its `h` tag)
    /// or the raw MLS group ID bytes. This is a security-critical property:
    /// FFI debug logs routinely surface via `debugPrint` on the Flutter side,
    /// and the group ID is never meant to be observable off-device.
    #[test]
    fn decrypt_result_ffi_debug_redacts_secrets() {
        let secret_group_id_bytes = vec![
            0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0x00, 0x11, 0x22, 0x33,
        ];
        let secret_hex = "deadbeefcafebabe00112233";
        let secret_event_json = format!(
            r#"{{"kind":445,"tags":[["h","{secret_hex}"]],"content":"secret-ciphertext"}}"#
        );

        let result = DecryptResultFfi {
            location: None,
            group_updated: true,
            evolution_event_json: Some(secret_event_json.clone()),
            evolution_mls_group_id: Some(secret_group_id_bytes.clone()),
        };

        let debug_str = format!("{result:?}");

        assert!(
            !debug_str.contains(&secret_event_json),
            "Debug impl must not embed raw evolution event JSON: {debug_str}"
        );
        assert!(
            !debug_str.contains(secret_hex),
            "Debug impl must not leak MLS group ID hex fragment: {debug_str}"
        );
        assert!(
            !debug_str.contains("secret-ciphertext"),
            "Debug impl must not leak event content: {debug_str}"
        );

        assert!(debug_str.contains("has_evolution_event"));
        assert!(debug_str.contains("has_evolution_mls_group_id"));
        assert!(debug_str.contains("group_updated"));
    }

    /// Companion to the redaction test: confirm the `None` branches
    /// still render as `false` so downstream log parsing can distinguish
    /// "present-but-redacted" from "absent".
    #[test]
    fn decrypt_result_ffi_debug_reports_absence() {
        let result = DecryptResultFfi {
            location: None,
            group_updated: false,
            evolution_event_json: None,
            evolution_mls_group_id: None,
        };

        let debug_str = format!("{result:?}");

        assert!(debug_str.contains("has_evolution_event: false"));
        assert!(debug_str.contains("has_evolution_mls_group_id: false"));
        assert!(debug_str.contains("has_location: false"));
        assert!(debug_str.contains("group_updated: false"));
    }
}
