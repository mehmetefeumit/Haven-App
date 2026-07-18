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

/// On-disk filename for the encrypted circle-metadata DB (rollback-journal
/// mode → `-journal` sidecar).
const CIRCLES_DB_FILENAME: &str = "circles.db";

/// On-disk filename for the Dark Matter MLS-state DB (WAL mode →
/// `-wal`/`-shm` sidecars). Mirrors
/// [`haven_core::nostr::mls::StorageConfig::database_path`] (`session.sqlite`).
const MLS_SESSION_DB_FILENAME: &str = "session.sqlite";

/// Keyring key identifier for the Dark Matter MLS session passphrase. The
/// service identifier is the shared [`CIRCLES_DB_SERVICE`]; only the key id
/// differs. Mirrors the `MLS_DB_KEY_ID` constant in
/// `haven_core::nostr::mls::storage`.
const MLS_SESSION_DB_KEY_ID: &str = "mls.session.key.default";

/// On-disk filename for the PRE-Dark-Matter MLS-state DB (retained only for the
/// one-time first-launch cutover cleanup; see [`destroy_legacy_mls_state`]).
const LEGACY_MLS_DB_FILENAME: &str = "haven_mdk.db";

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

/// Removes one keyring entry, distinguishing "already gone" from a genuine
/// failure.
///
/// A missing entry (`NoEntry`) — or no store installed at all
/// (`NoDefaultStore`) — is treated as success: there is no key left at rest, so
/// the wipe is idempotent. Any OTHER error (a locked / unavailable Secret
/// Service, a platform failure) is a GENUINE failure: the encrypted DB key may
/// still live at rest, so it is propagated to the caller. The returned message
/// is generic/opaque — it never carries the service, key id, or the raw backend
/// error (Security: no secret/path leak).
fn remove_keyring_key(service: &str, key_id: &str) -> Result<(), String> {
    let entry = match keyring_core::Entry::new(service, key_id) {
        Ok(entry) => entry,
        // No store installed / no matching entry ⇒ nothing persisted for us to
        // leave at rest ⇒ already-clean slate (idempotent success).
        Err(keyring_core::Error::NoDefaultStore | keyring_core::Error::NoEntry) => return Ok(()),
        Err(_) => return Err("failed to remove a keyring key".to_string()),
    };
    match entry.delete_credential() {
        // Deleted, or already absent — both leave nothing at rest.
        Ok(()) | Err(keyring_core::Error::NoEntry) => Ok(()),
        // A locked / unavailable Secret Service (PlatformFailure /
        // NoStorageAccess / …) leaves the encrypted DB key at rest: surface it
        // so the M10.1 logout retry keeps its durable marker and re-attempts.
        Err(_) => Err("failed to remove a keyring key".to_string()),
    }
}

/// Removes the circles.db keyring entry. See [`remove_keyring_key`].
///
/// Used by the logout MLS-state wipe so a returning identity mints a fresh key
/// rather than inheriting the prior one.
fn remove_circles_db_key() -> Result<(), String> {
    remove_keyring_key(CIRCLES_DB_SERVICE, CIRCLES_DB_KEY_ID)
}

/// Removes the Dark Matter MLS session's DB keyring entry. See [`remove_keyring_key`].
///
/// The core `haven_core::nostr::mls::storage` provisions this key; we never
/// touch the core, only delete the keyring entry so the next identity
/// re-provisions a fresh `session.sqlite` passphrase (wipe-on-logout).
fn remove_mls_session_db_key() -> Result<(), String> {
    remove_keyring_key(CIRCLES_DB_SERVICE, MLS_SESSION_DB_KEY_ID)
}

/// Deletes one file, distinguishing "already gone" from a genuine failure.
///
/// A missing file (`NotFound`) is success (idempotent wipe). Any OTHER error
/// (file locked, permission denied, path is a directory) is a GENUINE failure:
/// an encrypted DB may still be readable at rest, so it is propagated. The
/// message is generic/opaque — never the path or the raw OS error (Security).
fn remove_file_strict(path: &std::path::Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("failed to delete a database file".to_string()),
    }
}

/// Best-effort deletion of a `SQLCipher` DB file and its WAL/SHM/journal
/// sidecars under `data_dir`.
///
/// The `-wal`/`-shm` sidecars hold `SQLCipher`-encrypted pages not yet
/// checkpointed into the main file, and `-journal` a transient rollback
/// journal; all MUST be deleted alongside the base file so no MLS state or
/// circle metadata lingers at rest. Missing files are not an error.
///
/// EVERY sidecar is attempted even if an earlier one fails, so a single locked
/// file never strands the others; a genuine (non-`NotFound`) failure on ANY of
/// them is reported so the caller can surface it (M10.1 retries the wipe).
fn delete_db_files(data_dir: &str, filename: &str) -> Result<(), String> {
    let base = std::path::Path::new(data_dir).join(filename);
    let mut failed = false;
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let path = if suffix.is_empty() {
            base.clone()
        } else {
            let mut s = base.clone().into_os_string();
            s.push(suffix);
            std::path::PathBuf::from(s)
        };
        if remove_file_strict(&path).is_err() {
            failed = true;
        }
    }
    if failed {
        Err("failed to delete a database file".to_string())
    } else {
        Ok(())
    }
}

/// Deletes `circles.db` (+ sidecars) under `data_dir`. See [`delete_db_files`].
fn delete_circles_db_files(data_dir: &str) -> Result<(), String> {
    delete_db_files(data_dir, CIRCLES_DB_FILENAME)
}

/// Deletes `session.sqlite` (+ sidecars) under `data_dir`. See [`delete_db_files`].
fn delete_mls_session_db_files(data_dir: &str) -> Result<(), String> {
    delete_db_files(data_dir, MLS_SESSION_DB_FILENAME)
}

/// Deletes the PRE-Dark-Matter `haven_mdk.db` (+ sidecars) under `data_dir` —
/// the first-launch cutover cleanup. See [`delete_db_files`].
fn delete_legacy_mls_db_files(data_dir: &str) -> Result<(), String> {
    delete_db_files(data_dir, LEGACY_MLS_DB_FILENAME)
}

/// Wipes ALL local NEW-STACK MLS state on logout: deletes both encrypted
/// databases' files (`circles.db` and the Dark Matter `session.sqlite`, plus
/// every WAL/SHM/journal sidecar) and then removes both keyring keys.
///
/// This is the highest-severity teardown in the logout path: it guarantees a
/// returning (or different) identity never inherits the prior identity's MLS
/// group state, circle metadata, dedup cache, sync cursors, or DB keys. It
/// targets the NEW Dark Matter stack (`session.sqlite` +
/// `mls.session.key.default`); the PRE-Dark-Matter legacy DB/key are handled
/// separately by the one-time first-launch cutover ([`destroy_legacy_mls_state`]).
///
/// # Ordering and safety
///
/// The Dart caller MUST have dropped its `CircleManagerFfi` handle (so the last
/// `Arc<CoreCircleManager>` is gone and both SQLite connections have closed)
/// and stopped any live subscriptions BEFORE calling this — that is the Flutter
/// layer's responsibility. No Rust global holds the manager, so there is
/// nothing for this function to `.take()`. (Rule 14: at most one live session
/// per DB file — the handle drop closes it.)
///
/// This function is **idempotent**: deleting an already-gone file or key is not
/// an error, so a partial prior wipe or a double-call both converge to "nothing
/// left" and return `Ok(())` — the M10.1 launch-retry relies on this to avoid an
/// infinite loop. It relies on POSIX unlink semantics rather than GC timing —
/// should a file descriptor still be briefly open (e.g. an in-flight blocking
/// call that cloned the `Arc` just before the handle drop), `remove_file`
/// unlinks the path immediately and the kernel reclaims the inode once the last
/// descriptor closes; no new at-rest data is written to a file we are unlinking
/// under a key we are removing.
///
/// # Errors
///
/// Returns `Err` if ANY teardown step hit a GENUINE failure (a file locked /
/// permission-denied / not-a-file, or a locked / unavailable keyring) — as
/// opposed to "already gone", which is success. Surfacing a genuine failure is
/// load-bearing: it tells the Dart M10.1 logout to KEEP its durable retry
/// marker and re-attempt on the next launch, instead of clearing it and leaving
/// a decryptable `circles.db` / `session.sqlite` + keyring key at rest. The
/// error string is generic/opaque — no path, key id, or backend detail (Security).
pub async fn wipe_all_mls_state(data_dir: String) -> Result<(), String> {
    run_blocking(move || {
        // Delete DB files first (POSIX-safe even if a descriptor briefly
        // outlives the handle drop), THEN remove the keyring keys so a fresh
        // open after this mints new keys against a clean on-disk slate.
        //
        // Attempt EVERY step even if an earlier one fails, so a single locked
        // file / unavailable keyring never strands the rest; surface a genuine
        // failure only (an "already gone" step returns Ok and does not set the
        // flag, preserving idempotency for the launch-retry).
        let mut failed = false;
        failed |= delete_circles_db_files(&data_dir).is_err();
        failed |= delete_mls_session_db_files(&data_dir).is_err();
        failed |= remove_circles_db_key().is_err();
        failed |= remove_mls_session_db_key().is_err();
        if failed {
            Err("failed to fully wipe local MLS state".to_string())
        } else {
            Ok(())
        }
    })
    .await
}

/// First-launch cutover hook (Dark Matter §6 step 2 / security F6): destroys ALL
/// PRE-Dark-Matter MLS state so the new stack starts on a clean slate and the
/// old key material is gone.
///
/// Deletes the legacy `haven_mdk.db` (+ WAL/SHM/journal sidecars) AND destroys
/// the legacy keyring entry `mdk.db.key.default` (via the core helper). The old
/// DB was NOT written with `secure_delete` and flash wear-leveling can leave
/// residual ciphertext, so key destruction is the practical secure-erase for
/// the abandoned SQLCipher DB (F6). Distinct from [`wipe_all_mls_state`]: THIS
/// destroys LEGACY state (a one-time migration), that wipes NEW-stack state on
/// logout.
///
/// Idempotent and fail-soft on "already gone"; the Dart cutover guard should
/// call this ONCE on the first launch of the Dark Matter build (before opening
/// the new `CircleManagerFfi`), keyed off a persisted one-time flag.
///
/// # Errors
///
/// Returns `Err` (generic/opaque) if deleting a legacy DB file or destroying the
/// legacy keyring key hit a GENUINE failure (locked file / unavailable keyring),
/// so the Dart guard KEEPS its "cutover pending" flag and retries next launch.
pub async fn destroy_legacy_mls_state(data_dir: String) -> Result<(), String> {
    run_blocking(move || {
        let mut failed = false;
        failed |= delete_legacy_mls_db_files(&data_dir).is_err();
        // Key destruction is the practical secure-erase for the abandoned DB.
        failed |= haven_core::nostr::mls::storage::destroy_legacy_mls_key_material().is_err();
        if failed {
            Err("failed to destroy legacy MLS state".to_string())
        } else {
            Ok(())
        }
    })
    .await
}

/// Process-wide serialization for EVERY test that creates a `CircleManagerFfi`
/// or otherwise touches the shared, fixed keyring key-ids (`circles.db.key` /
/// `mdk.db.key.default`) — the M10 wipe end-to-end tests AND the
/// `maintenance_real_ffi_tests` (tc1/tc2/tc3).
///
/// `CircleManagerFfi::new` provisions those fixed global key-ids, so a `tc*`
/// create running concurrently with an M10 wipe could re-provision a key
/// between the wipe and its "key absent" assertion, flaking it. A single shared
/// lock across both test modules keeps their create→assert→wipe sequences from
/// interleaving.
///
/// It is a `tokio::sync::Mutex` (not `std::sync`) so the async `tc*` tests can
/// hold the guard across `.await` points without making their futures non-Send;
/// the synchronous M10 tests take it via `blocking_lock` (they run under no
/// ambient runtime, so that cannot panic).
#[cfg(test)]
static SHARED_KEYRING_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

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
    if haven_core::keyring_policy::ensure_db_key_after_first_unlock(TILES_DB_SERVICE, TILES_DB_KEY_ID)
        .is_err()
    {
        // Static message (no interpolation): a tile-layer log line must never
        // embed a value (check_no_tile_cache_secrets). Non-fatal — the migration
        // restored the key, so the cache stays fully functional.
        log::warn!("tiles.db key access-policy migration deferred (non-fatal)");
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
    Circle as CoreCircle, CircleConfig as CoreCircleConfig, CircleManager as CoreCircleManager,
    CircleMember as CoreCircleMember, CircleType as CoreCircleType,
    CircleWithMembers as CoreCircleWithMembers, Contact as CoreContact,
    Invitation as CoreInvitation,
};
use haven_core::nostr::mls::types::{GroupId, GroupIdExt, PendingStateRef};

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
#[derive(Clone)]
pub struct CircleMemberFfi {
    /// Nostr public key (hex) - always available.
    pub pubkey: String,
    /// Nostr public key in NIP-19 bech32 format (`npub1...`).
    ///
    /// A derived, display/copy-friendly encoding of [`Self::pubkey`]. An npub is
    /// a PUBLIC key, so it is safe to compute and expose.
    pub npub: String,
    /// Display name from local Contact, if set.
    pub display_name: Option<String>,
    /// Whether this member is a group admin.
    pub is_admin: bool,
}

/// Redacting `Debug` that mirrors the core [`CoreCircleMember`] impl
/// (see `haven-core/src/circle/types.rs`): public keys are truncated to a short
/// prefix and the local `display_name` is elided. Even though `pubkey`/`npub`
/// are PUBLIC keys, we never print them in full (Security Rule 6: no key
/// material in logs) so accidental `{:?}` formatting cannot leak identifiers.
impl std::fmt::Debug for CircleMemberFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleMemberFfi")
            .field(
                "pubkey",
                &format_args!("{}...", &self.pubkey[..16.min(self.pubkey.len())]),
            )
            .field(
                "npub",
                &format_args!("{}...", &self.npub[..16.min(self.npub.len())]),
            )
            .field("display_name", &"<redacted>")
            .field("is_admin", &self.is_admin)
            .finish()
    }
}

impl From<&CoreCircleMember> for CircleMemberFfi {
    fn from(m: &CoreCircleMember) -> Self {
        Self {
            npub: hex_to_npub(&m.pubkey),
            pubkey: m.pubkey.clone(),
            display_name: m.display_name.clone(),
            is_admin: m.is_admin,
        }
    }
}

/// Bech32-encodes a hex Nostr public key as an `npub1...` string (NIP-19).
///
/// An npub is a PUBLIC key, so it is safe to compute and expose across FFI.
/// On the (in practice impossible) parse/encode failure of a well-formed hex
/// member pubkey, falls back to the original hex so the UI never renders an
/// empty identifier.
fn hex_to_npub(hex: &str) -> String {
    use nostr::prelude::ToBech32 as _;
    nostr::PublicKey::parse(hex)
        .ok()
        .and_then(|pk| pk.to_bech32().ok())
        .unwrap_or_else(|| hex.to_string())
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

/// A publish-before-apply token (FFI mirror of `PendingStateRef`).
///
/// The Dark Matter engine stages a group-evolving commit and returns an opaque
/// `PendingStateRef` (a `u64` newtype). Haven publishes the commit (and, for an
/// Add, the welcomes), and ONLY after ≥1 relay returns OK confirms the token via
/// [`CircleManagerFfi::confirm_published`] so the engine applies the commit and
/// advances the epoch (Rule 13, publish-before-apply). On publish FAILURE the
/// token is rolled back via [`CircleManagerFfi::publish_failed`]. The `token` is
/// an in-memory session handle — meaningless across a process restart, never
/// persisted, never published.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PendingStateRefFfi {
    /// The opaque engine token (a `PendingStateRef` `u64`).
    pub token: u64,
}

impl From<PendingStateRef> for PendingStateRefFfi {
    fn from(p: PendingStateRef) -> Self {
        Self { token: p.as_u64() }
    }
}

impl From<PendingStateRefFfi> for PendingStateRef {
    fn from(p: PendingStateRefFfi) -> Self {
        Self::new(p.token)
    }
}

/// Result of circle creation (FFI-friendly).
///
/// Publish-before-apply (Rule 13): publish `welcome_events`, then confirm
/// `pending` via [`CircleManagerFfi::confirm_published`] once ≥1 relay ACKs a
/// welcome (or roll back via [`CircleManagerFfi::publish_failed`]).
#[derive(Debug, Clone)]
pub struct CircleCreationResultFfi {
    /// The created circle.
    pub circle: CircleFfi,
    /// Gift-wrapped Welcome events ready to publish to recipients.
    /// Each is a kind 1059 event containing an encrypted kind 444 Welcome.
    pub welcome_events: Vec<GiftWrappedWelcomeFfi>,
    /// The pending group-creation state to confirm after ≥1-relay welcome ACK.
    pub pending: PendingStateRefFfi,
}

/// Result of adding members to an existing circle (FFI-friendly).
///
/// Publish-before-apply (Rule 13): publish `commit_event_json`, confirm
/// `pending`, THEN publish `welcome_events` (a welcome for a losing/unconfirmed
/// commit references an epoch that never applied).
#[derive(Clone)]
pub struct AddMembersResultFfi {
    /// JSON-serialized kind 445 evolution (Add commit) event, to publish to
    /// the circle's relays before confirming `pending`.
    pub commit_event_json: String,
    /// Gift-wrapped Welcome events for the newly added members.
    /// Each is a kind 1059 event containing an encrypted kind 444 Welcome.
    /// Publish these only after `commit_event_json` is published and `pending`
    /// is confirmed.
    pub welcome_events: Vec<GiftWrappedWelcomeFfi>,
    /// The pending commit to confirm after ≥1-relay commit ACK.
    pub pending: PendingStateRefFfi,
}

impl std::fmt::Debug for AddMembersResultFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The commit-event JSON can embed the MLS group ID in its tags;
        // redact it. Welcome events redact themselves via their own Debug impl.
        f.debug_struct("AddMembersResultFfi")
            .field("commit_event_json", &"<redacted>")
            .field("welcome_events_count", &self.welcome_events.len())
            .field("pending", &self.pending)
            .finish()
    }
}

/// A group-evolving commit awaiting publish + confirm (remove / relay update /
/// admin change) — FFI mirror of `haven_core::circle::CommitToPublish`.
///
/// Publish-before-apply (Rule 13): publish `commit_event_json` to the circle's
/// relays, then confirm `pending` via [`CircleManagerFfi::confirm_published`]
/// on ≥1-relay ACK (or roll back via [`CircleManagerFfi::publish_failed`]).
#[derive(Clone)]
pub struct CommitToPublishFfi {
    /// JSON-serialized kind 445 commit event to publish to the circle's relays.
    pub commit_event_json: String,
    /// The pending commit to confirm after ≥1-relay ACK.
    pub pending: PendingStateRefFfi,
}

impl std::fmt::Debug for CommitToPublishFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The commit-event JSON's `h` tag carries the nostr_group_id; redact.
        f.debug_struct("CommitToPublishFfi")
            .field("commit_event_json", &"<redacted>")
            .field("pending", &self.pending)
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
}

impl std::fmt::Debug for DecryptedLocationFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DecryptedLocationFfi")
            .field("sender_pubkey", &"<redacted>")
            .field("latitude", &"<redacted>")
            .field("longitude", &"<redacted>")
            .field("geohash", &"<redacted>")
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

/// Discriminator for [`LocationMessageResultFfi`].
///
/// Mirrors the five
/// [`haven_core::nostr::mls::types::LocationMessageResult`] variants 1:1
/// (Dark Matter taxonomy). Unlike the pre-migration outcome, stale / duplicate
/// / out-of-order handling is entirely engine-internal (the engine durably
/// buffers a future-epoch event and re-surfaces it once the gap fills), so
/// there is NO `Unprocessable` / `PreviouslyFailed` here. A struct-with-
/// discriminant shape (rather than a tagged Rust enum) follows the existing
/// [`LeavePlanFfi`] convention and avoids pulling Dart `freezed` into the
/// generated bindings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocationMessageResultKindFfi {
    /// A decrypted application (location) message.
    Location,
    /// The local client joined a group via an accepted welcome.
    Joined,
    /// A durable, MLS-authenticated change to group state (membership, admin,
    /// rename, retention) or an epoch advance the receiver should react to by
    /// refreshing the circle's roster.
    GroupUpdate,
    /// A previously-surfaced result was withdrawn because branch selection
    /// superseded the commit that produced it — the caller must treat the
    /// earlier change as if it never happened.
    Invalidated,
    /// The group entered the unrecoverable state; the UI MUST block
    /// send/mutate for it (Rule 8, blocked-group state).
    Unrecoverable,
}

/// One folded engine [`haven_core::nostr::mls::types::LocationMessageResult`],
/// FFI-friendly. A single `kind:445` ingest can yield SEVERAL of these (an
/// engine `advance_convergence` may release buffered inbound after the outer
/// event), so [`CircleManagerFfi::decrypt_location`] returns a `Vec` of them.
///
/// Cursor contract (DM-4b): the engine now owns out-of-order buffering, so the
/// caller advances its relay sync cursor on the OUTER event's `created_at`
/// (which Dart already holds — it passed `event_json` in), NOT per result.
/// A buffered future-epoch event is re-surfaced by the engine once the gap
/// fills; the caller never needs to re-fetch it.
pub struct LocationMessageResultFfi {
    /// Which of the five outcomes this result is.
    pub kind: LocationMessageResultKindFfi,
    /// The decrypted location — `Some` only when `kind == Location` AND the
    /// inner content parsed as a `LocationMessage`. A successfully-decrypted
    /// but unparseable inner (e.g. a forward-incompatible payload) still yields
    /// `kind == Location` with `location == None` (decrypt succeeded).
    pub location: Option<DecryptedLocationFfi>,
    /// The MLS group id (raw bytes) this result belongs to — the LOCAL circle
    /// handle (never published; Rule 4 keeps it off the wire). Present for
    /// every variant so the caller can refresh / join / block / withdraw the
    /// right circle.
    pub mls_group_id: Vec<u8>,
    /// The MLS epoch the message was authenticated at — meaningful only for
    /// `kind == Location` (0 otherwise).
    pub epoch: u64,
}

impl std::fmt::Debug for LocationMessageResultFfi {
    /// Redacts payloads (location, raw group id) and exposes only presence;
    /// `epoch` is a non-secret counter.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocationMessageResultFfi")
            .field("kind", &self.kind)
            .field("has_location", &self.location.is_some())
            .field("mls_group_id", &"<redacted>")
            .field("epoch", &self.epoch)
            .finish()
    }
}

/// Converts a core [`LocationMessageResult`] into the FFI
/// [`DecryptOutcomeFfi`], surfacing all four variants.
///
/// Pure and synchronous (no MDK / no FFI / no async) so the M1 safety
/// contract — `Unprocessable` and `PreviouslyFailed` are SURFACED, not
/// flattened away — is unit-testable without a live `CircleManager`.
/// `event_created_at_secs` is the outer event timestamp, threaded through
/// onto every outcome.
///
/// [`LocationMessageResult`]: haven_core::nostr::mls::types::LocationMessageResult
///
/// # Errors
///
/// Returns a redacted error string if a `Location` payload cannot be parsed
/// or a `GroupUpdate` evolution event cannot be serialized.
/// Parses an engine-delivered Location `content` (the decrypted `LocationMessage`
/// JSON carried on `FfiRelayEvent.content`) into a structured
/// [`DecryptedLocationFfi`], reusing the Rust `serde` schema so the Dart stream
/// consumer (M6-3) never duplicates the content schema or the `DateTime` format.
/// The `sender_pubkey` comes from the stream event, not the content.
///
/// # Errors
///
/// Returns an error if `content_json` is not a valid `LocationMessage`.
pub fn parse_engine_location(
    content_json: String,
    sender_pubkey: String,
) -> Result<DecryptedLocationFfi, String> {
    // Fixed message — never interpolate the serde error, which could echo a
    // fragment of the decrypted location content (defense-in-depth; the Dart
    // consumer already discards this and logs only the runtime type).
    let location: haven_core::location::LocationMessage =
        serde_json::from_str(&content_json).map_err(|_| "invalid location content".to_string())?;
    Ok(DecryptedLocationFfi {
        // Normalize to lowercase so the Dart self-compare against the cached own
        // pubkey is case-insensitive by construction (mirrors convert_location_result).
        sender_pubkey: normalize_pubkey_hex(&sender_pubkey),
        latitude: location.latitude,
        longitude: location.longitude,
        geohash: location.geohash,
        timestamp: location.timestamp.timestamp(),
        expires_at: location.expires_at.timestamp(),
    })
}

/// Converts a core [`LocationMessageResult`] into the FFI
/// [`LocationMessageResultFfi`] (Dark Matter five-variant taxonomy).
///
/// Pure and synchronous (no engine / no FFI / no async) so the fold is
/// unit-testable without a live `CircleManager`.
///
/// [`LocationMessageResult`]: haven_core::nostr::mls::types::LocationMessageResult
fn convert_location_result(
    result: haven_core::nostr::mls::types::LocationMessageResult,
) -> LocationMessageResultFfi {
    use haven_core::nostr::mls::types::LocationMessageResult as R;
    match result {
        R::Location {
            sender_pubkey,
            content,
            group_id,
            epoch,
        } => {
            // Decrypt succeeded — a location result regardless of whether the
            // inner content parses. A forward-incompatible inner (from a peer
            // on a newer content schema) decrypts fine but yields `None`; the
            // caller advances past it exactly like a `GroupUpdate`.
            let location = serde_json::from_str::<haven_core::location::LocationMessage>(&content)
                .ok()
                .map(|location| DecryptedLocationFfi {
                    // Normalize to lowercase so the Dart self-compare against
                    // the cached own pubkey is case-insensitive by construction.
                    sender_pubkey: normalize_pubkey_hex(&sender_pubkey),
                    latitude: location.latitude,
                    longitude: location.longitude,
                    geohash: location.geohash,
                    timestamp: location.timestamp.timestamp(),
                    expires_at: location.expires_at.timestamp(),
                });
            LocationMessageResultFfi {
                kind: LocationMessageResultKindFfi::Location,
                location,
                mls_group_id: group_id.as_slice().to_vec(),
                epoch,
            }
        }
        R::Joined { group_id } => LocationMessageResultFfi {
            kind: LocationMessageResultKindFfi::Joined,
            location: None,
            mls_group_id: group_id.as_slice().to_vec(),
            epoch: 0,
        },
        R::GroupUpdate { group_id } => LocationMessageResultFfi {
            kind: LocationMessageResultKindFfi::GroupUpdate,
            location: None,
            mls_group_id: group_id.as_slice().to_vec(),
            epoch: 0,
        },
        R::Invalidated { group_id } => LocationMessageResultFfi {
            kind: LocationMessageResultKindFfi::Invalidated,
            location: None,
            mls_group_id: group_id.as_slice().to_vec(),
            epoch: 0,
        },
        R::Unrecoverable { group_id } => LocationMessageResultFfi {
            kind: LocationMessageResultKindFfi::Unrecoverable,
            location: None,
            mls_group_id: group_id.as_slice().to_vec(),
            epoch: 0,
        },
    }
}

/// The folded outcome of ingesting one received `kind:445` — FFI mirror of
/// `haven_core::circle::DecryptedIngest`.
///
/// Carries the folded location results AND any receive-side auto-commit the
/// engine staged (a peer `SelfRemove` eviction). Publish-before-apply (Rule 13 /
/// security F13): for EACH [`Self::auto_commits`] entry, publish
/// `commit_event_json` to the circle's relays, then
/// [`CircleManagerFfi::confirm_published`] on a ≥1-relay ACK (or
/// [`CircleManagerFfi::publish_failed`] on failure) — exactly like the
/// [`CommitToPublishFfi`] returned by remove / relay-update. NEVER confirm before
/// a relay ACKs, and NEVER drop an entry silently (that re-forks the group the
/// leaver departed).
///
/// Both fields carry redacting `Debug` impls (`LocationMessageResultFfi` /
/// `CommitToPublishFfi`), so the derived `Debug` here cannot leak group ids or
/// coordinates.
#[derive(Debug)]
pub struct DecryptLocationOutcomeFfi {
    /// The folded location-facing results (locations, joins, updates, …).
    pub results: Vec<LocationMessageResultFfi>,
    /// Receive-side auto-commits the caller MUST publish then confirm/fail.
    pub auto_commits: Vec<CommitToPublishFfi>,
}

/// Converts a Nostr event `created_at` (Unix seconds) to the millisecond unit
/// the sync cursor stores.
///
/// Saturating, so a pathological future timestamp cannot overflow `i64`.
/// Centralizing the seconds→milliseconds conversion here (rather than in Dart)
/// removes the ms/s drift footgun at the FFI boundary.
const fn event_secs_to_cursor_ms(secs: i64) -> i64 {
    secs.saturating_mul(1000)
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

// ==================== Relay preferences (kind 10050 / 10002) ====================
//
// FFI mirror of `haven_core::circle::RelayType`. Compile-time exhaustive on
// the Dart side so we never round-trip a stringly-typed slug across the
// boundary. Conversions live next to the type so they are easy to audit.
//
// RelayTypeFfi decision (Dark Matter W2): the pre-migration `KeyPackage`
// variant (kind 10051) is RETIRED in favor of `Nip65` (kind 10002). Under Dark
// Matter, KeyPackages are discovered on the account's NIP-65 kind-10002 relays
// (the kind-10051 list is abolished + retracted at cutover). To avoid a
// storage/schema churn, `Nip65` maps onto the SAME underlying
// `RelayType::KeyPackage` storage slot + publish toggle (`publish_kp_relay_list`)
// — only the ON-WIRE publish kind changes from 10051 to 10002. So a user's
// "where my KeyPackage is discoverable" relay list is stored exactly as before;
// the publish/maintenance paths just emit kind 10002 (`r` tags) instead of
// 10051 (`relay` tags). The core `RelayType::KeyPackage` (10051) survives only
// for the one-time cutover RETRACTION of the abolished 10051 list.

/// Category of relay preference managed per user.
///
/// Mirrors [`haven_core::circle::RelayType`] with the Dark Matter W2 rename:
/// - [`RelayTypeFfi::Inbox`] → kind 10050 (NIP-17 welcome delivery).
/// - [`RelayTypeFfi::Nip65`] → kind 10002 (NIP-65; KeyPackage discovery under
///   Dark Matter). Persisted under the same slot the retired kind-10051
///   `KeyPackage` list used, so no relay-preference data migrates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayTypeFfi {
    /// Inbox relays (kind 10050, NIP-17).
    Inbox,
    /// NIP-65 relays (kind 10002) — where this account's KeyPackage is
    /// discoverable under Dark Matter (W2, replacing the retired kind-10051
    /// list). Stored under the `RelayType::KeyPackage` slot.
    Nip65,
}

impl From<RelayTypeFfi> for haven_core::circle::RelayType {
    fn from(t: RelayTypeFfi) -> Self {
        match t {
            RelayTypeFfi::Inbox => Self::Inbox,
            // `Nip65` shares the persisted `KeyPackage` slot (see banner).
            RelayTypeFfi::Nip65 => Self::KeyPackage,
        }
    }
}

impl From<haven_core::circle::RelayType> for RelayTypeFfi {
    fn from(t: haven_core::circle::RelayType) -> Self {
        match t {
            haven_core::circle::RelayType::Inbox => Self::Inbox,
            haven_core::circle::RelayType::KeyPackage => Self::Nip65,
        }
    }
}

/// The on-wire replaceable-list kind published for a relay-preference category
/// under Dark Matter: 10050 for Inbox, **10002 (NIP-65)** for the KeyPackage-
/// discovery list (W2; the kind-10051 list is retired).
fn relay_list_wire_kind(relay_type: RelayTypeFfi) -> nostr::Kind {
    match relay_type {
        RelayTypeFfi::Inbox => nostr::Kind::InboxRelays,
        RelayTypeFfi::Nip65 => nostr::Kind::RelayList,
    }
}

/// Builds the signed replaceable relay-list event for `relay_type`, choosing
/// the correct Dark Matter wire form: kind-10050 `relay` tags for Inbox,
/// kind-10002 `r` tags for the NIP-65 KeyPackage-discovery list (W2).
fn build_relay_list_event_for(
    relay_type: RelayTypeFfi,
    keys: &nostr::Keys,
    urls: &[String],
    created_at: Option<i64>,
) -> Result<nostr::Event, String> {
    match relay_type {
        RelayTypeFfi::Inbox => haven_core::relay::build_relay_list_event(
            keys,
            haven_core::circle::RelayType::Inbox,
            urls,
            created_at,
        ),
        RelayTypeFfi::Nip65 => {
            haven_core::relay::build_nip65_relay_list_event(keys, urls, created_at)
        }
    }
    .map_err(|e| format!("Failed to build relay list event: {e}"))
}

/// Builds the "empty replacement" event used to unpublish a relay-list category,
/// in the correct Dark Matter wire form: an empty kind-10050 replacement for
/// Inbox, an empty kind-10002 (NIP-65) replacement for the KeyPackage-discovery
/// list (W2). `last_published_at` floors the `created_at` so the replacement
/// strictly supersedes the previous list across clock skew.
fn build_relay_list_unpublish_for(
    relay_type: RelayTypeFfi,
    keys: &nostr::Keys,
    last_published_at: Option<i64>,
) -> Result<nostr::Event, String> {
    match relay_type {
        RelayTypeFfi::Inbox => haven_core::relay::build_unpublish_event(
            keys,
            haven_core::circle::RelayType::Inbox,
            last_published_at,
        ),
        RelayTypeFfi::Nip65 => haven_core::relay::build_nip65_relay_list_event(
            keys,
            &[],
            Some(haven_core::relay::superseding_created_at(last_published_at)),
        ),
    }
    .map_err(|e| format!("Failed to build replacement: {e}"))
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

/// Serializes a group-evolving commit event to JSON for the Dart publish path.
fn commit_event_to_json(event: &nostr::Event) -> Result<String, String> {
    serde_json::to_string(event).map_err(|e| format!("Failed to serialize commit event: {e}"))
}

/// Converts a core [`haven_core::circle::CommitToPublish`] into its FFI mirror.
fn convert_commit_to_publish(
    commit: haven_core::circle::CommitToPublish,
) -> Result<CommitToPublishFfi, String> {
    Ok(CommitToPublishFfi {
        commit_event_json: commit_event_to_json(&commit.commit_event)?,
        pending: commit.pending.into(),
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

/// Extracts the NIP-33 `d` tag value from a probed kind-30443 `KeyPackage`
/// event, if present. Used by [`RelayManagerFfi::maintain_key_package`] to
/// build the on-relay snapshot. Never logged.
#[inline]
fn kp_event_d_tag(event: &nostr::Event) -> Option<String> {
    event.tags.iter().find_map(|t| {
        let s = t.as_slice();
        (s.len() >= 2 && s[0] == "d").then(|| s[1].clone())
    })
}

/// Extracts the `["relay", <url>]` URLs from a probed kind-10050 (Inbox)
/// relay-list event, for drift detection in
/// [`RelayManagerFfi::maintain_relay_list_category`]. Never logged.
#[inline]
fn relay_list_urls(event: &nostr::Event) -> Vec<String> {
    event
        .tags
        .iter()
        .filter_map(|t| {
            let s = t.as_slice();
            (s.len() >= 2 && s[0] == "relay").then(|| s[1].clone())
        })
        .collect()
}

/// Extracts the `["r", <url>]` URLs from a probed kind-10002 (NIP-65)
/// relay-list event, for drift detection on the KeyPackage-discovery list under
/// Dark Matter (W2; NIP-65 tags relays as `r`, NOT the `relay` form 10050 uses).
#[inline]
fn nip65_relay_list_urls(event: &nostr::Event) -> Vec<String> {
    event
        .tags
        .iter()
        .filter_map(|t| {
            let s = t.as_slice();
            (s.len() >= 2 && s[0] == "r").then(|| s[1].clone())
        })
        .collect()
}

/// The on-relay URL extractor for a relay-list category's wire form: `relay`
/// tags for Inbox (10050), `r` tags for the NIP-65 KeyPackage list (10002).
#[inline]
fn relay_list_urls_for(relay_type: RelayTypeFfi, event: &nostr::Event) -> Vec<String> {
    match relay_type {
        RelayTypeFfi::Inbox => relay_list_urls(event),
        RelayTypeFfi::Nip65 => nip65_relay_list_urls(event),
    }
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

/// Derives identity [`Keys`] from 32-byte secret bytes, failing closed on a
/// wrong length or malformed key. Wraps the input in `Zeroizing` so an
/// early-return path never leaks the secret (Security Rule 7/9).
///
/// [`Keys`]: nostr::Keys
fn keys_from_secret_bytes(identity_secret_bytes: Vec<u8>) -> Result<nostr::Keys, String> {
    let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
    if identity_secret_bytes.len() != 32 {
        return Err("Invalid secret bytes length".to_string());
    }
    let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
        .map_err(|e| format!("Invalid secret key: {e}"))?;
    Ok(nostr::Keys::new(secret_key))
}

impl CircleManagerFfi {
    /// Creates a new circle manager bound to the device identity.
    ///
    /// Initializes both the Dark Matter MLS session (`session.sqlite`) and the
    /// circle metadata database (`circles.db`) at the given data directory.
    /// Ensures the platform keyring store is initialized first (idempotent).
    ///
    /// # Dark Matter identity gating (DM-4)
    ///
    /// The Dark Matter [`SessionManager`] binds the device's Nostr identity as
    /// its account identity, its NIP-59 welcome signer, AND its hardened
    /// account-identity-proof signer (Rule 1), so the identity secret is now a
    /// HARD construction requirement — the engine cannot open without it.
    /// `identity_secret_bytes` (32 bytes, from
    /// `NostrIdentityManager.get_secret_bytes()`) MUST be present; a wrong
    /// length or missing identity fails closed with a clear error, matching the
    /// existing identity-gating call sites. The bytes are `Zeroizing`-wrapped
    /// and dropped before this returns.
    ///
    /// [`SessionManager`]: haven_core::nostr::mls::SessionManager
    pub fn new(data_dir: String, identity_secret_bytes: Vec<u8>) -> Result<Self, String> {
        let keys = keys_from_secret_bytes(identity_secret_bytes)?;
        init_keyring_store()?;
        let circle_db_key = get_or_create_circle_db_key()?;
        let path = Path::new(&data_dir);
        CoreCircleManager::new(path, &keys, Some(&circle_db_key))
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
        let keys = keys_from_secret_bytes(identity_secret_bytes)?;

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

        // Convert gift-wrapped welcome events to FFI. F3: if serialization fails
        // after the create was staged, roll the pending back BEFORE returning
        // (the core `publish_failed` also deletes the just-saved circle rows), so
        // neither a leaked `PendingStateRef` nor a ghost circle row survives.
        let pending_ref = result.pending;
        let welcome_events: Vec<GiftWrappedWelcomeFfi> = match result
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
            .collect::<Result<Vec<_>, String>>()
        {
            Ok(events) => events,
            Err(e) => {
                let _ = self.inner.publish_failed(pending_ref).await;
                return Err(e);
            }
        };

        let pending = pending_ref.into();
        Ok(CircleCreationResultFfi {
            circle: CircleFfi::from(&result.circle),
            welcome_events,
            pending,
        })
    }

    /// Gets a circle by its MLS group ID.
    ///
    /// Async: resolving the roster reads the Dark Matter session (which is
    /// `&mut`-serialized behind a `tokio` mutex), so this awaits directly on
    /// the current worker rather than dispatching to the blocking pool.
    pub async fn get_circle(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<Option<CircleWithMembersFfi>, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        self.inner
            .get_circle(&group_id)
            .await
            .map(|opt| opt.map(|c| CircleWithMembersFfi::from(&c)))
            .map_err(|e| e.to_string())
    }

    /// Gets all circles.
    pub async fn get_circles(&self) -> Result<Vec<CircleWithMembersFfi>, String> {
        self.inner
            .get_circles()
            .await
            .map(|circles| circles.iter().map(CircleWithMembersFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Gets visible circles (excludes declined invitations).
    pub async fn get_visible_circles(&self) -> Result<Vec<CircleWithMembersFfi>, String> {
        self.inner
            .get_visible_circles()
            .await
            .map(|circles| circles.iter().map(CircleWithMembersFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Classifies the leave operation — see [`LeavePlanFfi`] for the
    /// Flutter-side state machine.
    pub async fn plan_leave(
        &self,
        mls_group_id: Vec<u8>,
        self_pubkey_hex: String,
    ) -> Result<LeavePlanFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let self_pk = nostr::PublicKey::from_hex(&self_pubkey_hex)
            .map_err(|_| "Invalid self_pubkey_hex".to_string())?;
        let plan = self
            .inner
            .plan_leave(&group_id, &self_pk)
            .await
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
    }

    /// Step 1 of admin handoff: propose promoting `successor_hex` to admin.
    ///
    /// # GAP (plan §5.2 #18)
    ///
    /// The Dark Matter v0.9.4 public API exposes no admin-policy component
    /// codec, so this currently returns a documented error (the core method
    /// fails closed). Kept so the Dart leave state machine keeps its shape.
    pub async fn propose_admin_handoff(
        &self,
        mls_group_id: Vec<u8>,
        successor_hex: String,
    ) -> Result<CommitToPublishFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let successor = nostr::PublicKey::from_hex(&successor_hex)
            .map_err(|_| "Invalid successor_hex".to_string())?;
        let commit = self
            .inner
            .propose_admin_handoff(&group_id, &successor)
            .await
            .map_err(|e| e.to_string())?;
        convert_commit_to_publish(commit)
    }

    /// Admin: replace this circle's group relay list (MIP-01) via an
    /// `UpdateAppComponents(nostr-routing.v1)` commit.
    ///
    /// Returns a [`CommitToPublishFfi`]. Publish `commit_event_json` to the
    /// **union of the circle's current relays and `new_relays`** (so a member
    /// only listening on a relay being removed still receives the commit), then
    /// call [`finalize_relay_update`](Self::finalize_relay_update) on a ≥1-relay
    /// ACK or [`publish_failed`](Self::publish_failed) on failure. `new_relays`
    /// MUST be non-empty, `wss://` (or the debug loopback test seam),
    /// credential-free, and at most 20 entries; admin authorization is enforced
    /// by the engine against live MLS state.
    pub async fn update_circle_relays(
        &self,
        mls_group_id: Vec<u8>,
        new_relays: Vec<String>,
    ) -> Result<CommitToPublishFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let commit = self
            .inner
            .update_circle_relays(&group_id, &new_relays)
            .await
            .map_err(|e| e.to_string())?;
        convert_commit_to_publish(commit)
    }

    /// Step 2 of admin handoff (or step 1 of `Abandon`): demote self from admin.
    ///
    /// # GAP (plan §5.2 #18)
    ///
    /// Same admin-policy-codec gap as [`propose_admin_handoff`](Self::propose_admin_handoff);
    /// the core method currently returns a documented error.
    pub async fn propose_self_demote(
        &self,
        mls_group_id: Vec<u8>,
    ) -> Result<CommitToPublishFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let commit = self
            .inner
            .propose_self_demote(&group_id)
            .await
            .map_err(|e| e.to_string())?;
        convert_commit_to_publish(commit)
    }

    /// Returns a `SelfRemove` proposal event JSON. Publish it, then call
    /// [`complete_leave`](Self::complete_leave).
    ///
    /// A bare `SelfRemove` proposal has NO `PendingStateRef` — a remaining
    /// member commits it later (RFC 9420 §12.1.2), so there is nothing to
    /// confirm or roll back. The returned string is the signed kind:445 event
    /// JSON to publish to the circle's relays.
    pub async fn propose_leave(&self, mls_group_id: Vec<u8>) -> Result<String, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let event = self
            .inner
            .propose_leave(&group_id)
            .await
            .map_err(|e| e.to_string())?;
        commit_event_to_json(&event)
    }

    /// Removes the local circle row after a successful leave sequence, or
    /// for the `OrphanLocalOnly` plan. (Storage-only; sync in the core.)
    pub async fn complete_leave(&self, mls_group_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let group_id = GroupId::from_slice(&mls_group_id);
            inner.complete_leave(&group_id).map_err(|e| e.to_string())
        })
        .await
    }

    /// Wipes local state for the `Abandon` plan — sole-member cleanup with
    /// no MLS commit and no relay publish. (Storage-only; sync in the core.)
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

    // ==================== Publish-before-apply (Rule 13) ====================

    /// Confirms a staged commit was published (≥1-relay OK-ack) so the engine
    /// applies it and advances the epoch.
    ///
    /// "Acked" MUST mean a relay returned OK — never merely "sent" — to avoid
    /// optimistic-merge forks (Rule 13, security F13). Pass the `pending` token
    /// carried in a [`CircleCreationResultFfi`] / [`AddMembersResultFfi`] /
    /// [`CommitToPublishFfi`].
    pub async fn confirm_published(&self, pending: PendingStateRefFfi) -> Result<(), String> {
        self.inner
            .confirm_published(pending.into())
            .await
            .map_err(|e| e.to_string())
    }

    /// Reports that a staged publish FAILED; the engine discards the staged
    /// commit and returns the group to `Stable` at the prior epoch.
    ///
    /// The publish-failure counterpart to [`confirm_published`](Self::confirm_published);
    /// pass the same `pending` token.
    pub async fn publish_failed(&self, pending: PendingStateRefFfi) -> Result<(), String> {
        self.inner
            .publish_failed(pending.into())
            .await
            .map_err(|e| e.to_string())
    }

    // ==================== Member Management ====================

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
        let keys = keys_from_secret_bytes(identity_secret_bytes)?;

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

        // `add_members_with_welcomes` is genuinely async (engine send +
        // giftwrap construction await), so it stays on the current tokio worker.
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

        let commit_event_json = commit_event_to_json(&result.commit_event)?;
        let pending = result.pending.into();

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
            commit_event_json,
            welcome_events,
            pending,
        })
    }

    /// Removes members from a circle.
    ///
    /// Returns a [`CommitToPublishFfi`] (publish-before-apply, Rule 13):
    /// publish `commit_event_json`, then [`confirm_published`](Self::confirm_published)
    /// on a ≥1-relay ACK or [`publish_failed`](Self::publish_failed) on failure.
    pub async fn remove_members(
        &self,
        mls_group_id: Vec<u8>,
        member_pubkeys: Vec<String>,
    ) -> Result<CommitToPublishFfi, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        let commit = self
            .inner
            .remove_members(&group_id, &member_pubkeys)
            .await
            .map_err(|e| e.to_string())?;
        convert_commit_to_publish(commit)
    }

    /// Gets members of a circle with resolved contact info.
    ///
    /// Async: reads the roster from the Dark Matter session (awaits directly).
    pub async fn get_members(&self, mls_group_id: Vec<u8>) -> Result<Vec<CircleMemberFfi>, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        self.inner
            .get_members(&group_id)
            .await
            .map(|members| members.iter().map(CircleMemberFfi::from).collect())
            .map_err(|e| e.to_string())
    }

    /// Returns whether `pubkey_hex` is still in the circle's current MLS
    /// roster — the REV-1 leaver-backstop liveness predicate.
    ///
    /// The Dart leave flow polls this with the leaver's OWN pubkey after
    /// publishing a `SelfRemove` (see [`propose_leave`](Self::propose_leave)):
    /// while it returns `true` the leaver re-issues a fresh `propose_leave` on
    /// each epoch advance; once it returns `false` the eviction has landed and
    /// [`complete_leave`](Self::complete_leave) can wipe local state. Fails
    /// SAFE to `false` when the group is gone or the caller has been evicted,
    /// so a removed leaver stops re-issuing. Error strings are hex-redacted by
    /// the core method (Security Rule 4/8).
    pub async fn still_a_member(
        &self,
        mls_group_id: Vec<u8>,
        pubkey_hex: String,
    ) -> Result<bool, String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        self.inner
            .still_a_member(&group_id, &pubkey_hex)
            .await
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
        let keys = keys_from_secret_bytes(identity_secret_bytes)?;

        // Parse the gift-wrapped event
        let gift_wrap_event: nostr::Event = serde_json::from_str(&gift_wrap_event_json)
            .map_err(|e| format!("Invalid gift wrap event JSON: {e}"))?;

        // Genuinely async — the Dark Matter peeler previews the welcome (peel
        // WITHOUT ingest, F3 hold-before-ingest) internally. The returned
        // `InvitationFfi.mlsGroupId` is a STAND-IN (the gift-wrap event id)
        // until Accept ingests and the engine yields the real MLS group id;
        // Dart passes that stand-in id back to `accept_invitation` /
        // `decline_invitation` (they key on the gift-wrap id).
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

    /// Gets all pending invitations from the in-memory held-welcome store.
    ///
    /// Each [`InvitationFfi`] carries pre-join STAND-IN fields (the gift-wrap
    /// event id as `mlsGroupId`, `"New Circle"` as the name, `memberCount == 0`)
    /// because the real MLS group state lives inside the still-encrypted 1059
    /// held until Accept (F3). The gift-wrap id is the key the caller passes to
    /// [`accept_invitation`](Self::accept_invitation) /
    /// [`decline_invitation`](Self::decline_invitation).
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

    /// Accepts an invitation to join a circle, keyed by the gift-wrap event id.
    ///
    /// Feeds the still-encrypted 1059 held for `gift_wrap_id` (the stand-in
    /// `mlsGroupId` bytes from [`process_gift_wrapped_invitation`]) to the
    /// engine, which peels + joins and yields the real circle.
    pub async fn accept_invitation(
        &self,
        gift_wrap_id: Vec<u8>,
    ) -> Result<CircleWithMembersFfi, String> {
        let event_id = nostr::EventId::from_slice(&gift_wrap_id)
            .map_err(|e| format!("Invalid gift-wrap id: {e}"))?;
        self.inner
            .accept_invitation(&event_id)
            .await
            .map(|c| CircleWithMembersFfi::from(&c))
            .map_err(|e| e.to_string())
    }

    /// Declines an invitation, keyed by the gift-wrap event id.
    ///
    /// Drops the held 1059 locally (never ingested → nothing on the wire,
    /// Rule 10) and marks the gift wrap resolved so a re-poll never re-surfaces
    /// it. (Storage-only; sync in the core.)
    pub async fn decline_invitation(&self, gift_wrap_id: Vec<u8>) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            let event_id = nostr::EventId::from_slice(&gift_wrap_id)
                .map_err(|e| format!("Invalid gift-wrap id: {e}"))?;
            inner
                .decline_invitation(&event_id)
                .map_err(|e| e.to_string())
        })
        .await
    }

    // ==================== Key Packages ====================

    // NOTE (Dark Matter): the old `create_key_package` / `sign_key_package_event`
    // / `record_published_key_packages` trio is RETIRED. It built the kind
    // 30443+443 TWIN from a `KeyPackageBundle`, which no longer exists — the
    // Dark Matter engine mints a single last-resort KeyPackage (`fresh_key_package`)
    // and the 443 twin is dropped (W1). The ONE onboarding/login/heal KeyPackage
    // publish path is now [`RelayManagerFfi::maintain_key_package`], which mints
    // via the engine, builds+signs the single kind-30443 event, publishes it to
    // the user's own NIP-65 relays, records the tracking row, and deletes the
    // minted material on a failed publish (mdk#160) — all under one idempotent,
    // fail-soft tick that also serves the first-ever publish (a responding relay
    // that serves nothing + no tracked slot ⇒ mint-fresh Republish). DM-4b
    // re-points onboarding/login to call `maintainKeyPackage`.

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

    // NOTE (Dark Matter): `self_update` and `groups_needing_self_update` are
    // RETIRED. The Dark Matter engine internalizes leaf-key rotation and
    // convergence (there is no app-driven periodic self-update; Haven already
    // shipped `enablePeriodicSelfUpdate = false`). The publish-before-apply
    // pending-commit lifecycle that `finalize_pending_commit` /
    // `clear_pending_commit` used to drive is now
    // [`confirm_published`](Self::confirm_published) /
    // [`publish_failed`](Self::publish_failed), keyed by the typed
    // `PendingStateRefFfi` token carried in each result — not by group id.

    /// Finalizes an admin relay update: confirms the pending commit, then
    /// re-syncs the admin's own `circle.relays` from the engine's routing
    /// component so the admin converges on the new set immediately.
    ///
    /// Use this instead of a bare [`confirm_published`](Self::confirm_published)
    /// for the [`update_circle_relays`](Self::update_circle_relays) flow
    /// (members converge via the receive path). Pass the `pending` token from
    /// the [`CommitToPublishFfi`] and the circle's `mls_group_id`.
    pub async fn finalize_relay_update(
        &self,
        pending: PendingStateRefFfi,
        mls_group_id: Vec<u8>,
    ) -> Result<(), String> {
        let group_id = GroupId::from_slice(&mls_group_id);
        self.inner
            .finalize_relay_update(pending.into(), &group_id)
            .await
            .map_err(|e| e.to_string())
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
        // Location messages no longer carry a display name: names moved to
        // public kind-0 profiles at the public-profile migration.
        let location = haven_core::location::LocationMessage::new(latitude, longitude);

        // `encrypt_location` sends via the Dark Matter engine (async), so it
        // awaits directly on the current worker.
        let group_id = GroupId::from_slice(&mls_group_id);
        let (event, nostr_group_id, relays) = self
            .inner
            .encrypt_location(&group_id, &sender_pubkey, &location, update_interval_secs)
            .await
            .map_err(|e| e.to_string())?;

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

    /// Decrypts / ingests a received `kind:445` event, returning the folded
    /// engine results (Dark Matter five-variant taxonomy).
    ///
    /// A single ingest can yield SEVERAL [`LocationMessageResultFfi`] — the
    /// engine's `advance_convergence` may release buffered inbound after the
    /// outer event — so this returns a `Vec`. The engine owns stale / duplicate
    /// / out-of-order handling internally (a future-epoch event is durably
    /// buffered and re-surfaced once the gap fills), so there is no
    /// `Unprocessable` / `PreviouslyFailed` outcome anymore.
    ///
    /// # Peer `SelfRemove` eviction (auto-commit) — Rule 13
    ///
    /// This variant does NOT surface receive-side auto-commits (a peer
    /// `SelfRemove` eviction the engine staged): to stay Rule-13-safe the core
    /// rolls back any that surfaced rather than confirm an unpublished commit.
    /// The eviction still propagates via the background catch-up sweep (which
    /// publishes it). Callers that own relay publishing in poll mode SHOULD
    /// migrate to [`Self::decrypt_location_collecting_commits`], which surfaces the
    /// auto-commit so the caller can publish-then-confirm it in the foreground.
    ///
    /// # Cursor contract (DM-4b)
    ///
    /// The engine owns retry/buffering, so the caller advances its relay sync
    /// cursor on the OUTER event's `created_at` (which the Dart caller already
    /// holds — it passed `event_json` in). A buffered event is re-delivered by
    /// the engine when the epoch gap fills; the caller never re-fetches it.
    ///
    /// # Concurrency
    ///
    /// The session is `&mut`-serialized behind a `tokio` mutex, so concurrent
    /// calls are serialized by the engine; this awaits directly.
    ///
    /// # Arguments
    ///
    /// * `event_json` - JSON-serialized `kind:445` event.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the event JSON is invalid or the
    /// engine ingest fails hard.
    pub async fn decrypt_location(
        &self,
        event_json: String,
    ) -> Result<Vec<LocationMessageResultFfi>, String> {
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;

        // Event id prefix for correlating diagnostic logs across publish /
        // fetch / decrypt. Nostr event ids are public on relays, so no cost.
        let evt_prefix: String = event.id.to_hex().chars().take(8).collect();

        // Defense-in-depth: the core `decrypt_location` already redacts its
        // error strings; re-redact at the boundary so the invariant is local.
        let results = self
            .inner
            .decrypt_location(&event)
            .await
            .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))?;

        let out: Vec<LocationMessageResultFfi> =
            results.into_iter().map(convert_location_result).collect();

        log::debug!("[FFI decrypt] evt={evt_prefix} → {} result(s)", out.len());

        Ok(out)
    }

    /// Decrypts / ingests a received `kind:445`, returning the folded results AND
    /// any receive-side auto-commit the engine staged (publish-before-apply).
    ///
    /// Identical ingest to [`Self::decrypt_location`], but surfaces a peer
    /// `SelfRemove` eviction the engine auto-committed instead of dropping it.
    /// Rule 13 / security F13: for EACH
    /// [`DecryptLocationOutcomeFfi::auto_commits`] entry, publish
    /// `commit_event_json` to the circle's relays, then
    /// [`confirm_published`](Self::confirm_published) on a ≥1-relay ACK (or
    /// [`publish_failed`](Self::publish_failed) on failure) — exactly like the
    /// [`CommitToPublishFfi`] from remove / relay-update. Confirming before an
    /// ACK, or dropping an entry, re-forks the group the leaver departed. The
    /// foreground poll receive path SHOULD call this in place of
    /// [`Self::decrypt_location`].
    ///
    /// The cursor contract of [`Self::decrypt_location`] applies unchanged.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the event JSON is invalid or the
    /// engine ingest fails hard.
    pub async fn decrypt_location_collecting_commits(
        &self,
        event_json: String,
    ) -> Result<DecryptLocationOutcomeFfi, String> {
        let event: nostr::Event =
            serde_json::from_str(&event_json).map_err(|e| format!("Invalid event JSON: {e}"))?;
        let evt_prefix: String = event.id.to_hex().chars().take(8).collect();

        let ingest = self
            .inner
            .decrypt_location_collecting_commits(&event)
            .await
            .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))?;

        let results: Vec<LocationMessageResultFfi> = ingest
            .results
            .into_iter()
            .map(convert_location_result)
            .collect();
        // F3: a convert failure MUST NOT drop the OTHER surfaced auto-commit
        // pendings on the floor. Collect every pending up-front so a mid-stream
        // failure rolls each staged receive-side auto-commit back item-by-item
        // (`publish_failed`) instead of leaking them — otherwise a group the
        // leaver departed silently re-forks (Rule 13 / security F13).
        let all_pendings: Vec<PendingStateRef> =
            ingest.auto_commits.iter().map(|c| c.pending).collect();
        let mut auto_commits: Vec<CommitToPublishFfi> =
            Vec::with_capacity(ingest.auto_commits.len());
        let mut convert_err: Option<String> = None;
        for commit in ingest.auto_commits {
            match convert_commit_to_publish(commit) {
                Ok(ffi) => auto_commits.push(ffi),
                Err(e) => {
                    convert_err = Some(e);
                    break;
                }
            }
        }
        if let Some(e) = convert_err {
            for pending in all_pendings {
                let _ = self.inner.publish_failed(pending).await;
            }
            return Err(e);
        }

        log::debug!(
            "[FFI decrypt] evt={evt_prefix} → {} result(s), {} auto-commit(s)",
            results.len(),
            auto_commits.len()
        );

        Ok(DecryptLocationOutcomeFfi {
            results,
            auto_commits,
        })
    }

    // ==================== Sync Cursors ====================

    /// Reads the persisted relay sync cursor (raw ms) for `stream`.
    ///
    /// Returns `None` when the stream has never been seeded — callers MUST
    /// seed a floor before opening a subscription. See
    /// [`haven_core::relay::cursor`] for stream keys and semantics.
    ///
    /// # Errors
    ///
    /// Returns an error string if the storage read fails.
    ///
    /// Storage errors here can only reference the constant `stream` key, the
    /// `sync_cursors` table, or an `i64`, never secret material — but they are
    /// still re-redacted via `redact_hex_sequences` so every error crossing
    /// this FFI boundary honors the same no-raw-hex invariant uniformly.
    pub async fn cursor_get(&self, stream: String) -> Result<Option<i64>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .read_sync_cursor(&stream)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Seeds `stream`'s cursor to `ms` only if it is currently unseeded.
    ///
    /// Idempotent: an already-seeded cursor is never moved.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the storage write fails.
    pub async fn cursor_seed_if_unset(&self, stream: String, ms: i64) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .seed_sync_cursor_if_unset(&stream, ms)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Advances `stream`'s cursor to `ms` (monotonic max; never backward).
    ///
    /// `ms` is a millisecond timestamp. Prefer the seconds-taking semantic
    /// wrappers [`Self::cursor_advance_group_to_event`] /
    /// [`Self::cursor_advance_inbox_to_wrap`], which own the stream key and the
    /// seconds→milliseconds conversion; reach for this generic form only when
    /// the caller already holds a millisecond value. There is intentionally no
    /// unconditional setter: the cursor only moves forward, and only for a
    /// successfully-processed event.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the storage write fails.
    pub async fn cursor_advance(&self, stream: String, ms: i64) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .advance_sync_cursor(&stream, ms)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Resets `stream`'s cursor to the unseeded state (wipe-on-logout).
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the storage write fails.
    pub async fn cursor_reset(&self, stream: String) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .reset_sync_cursor(&stream)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Advances the `group_445` cursor to a fully-processed `kind:445` event's
    /// `created_at` (Unix **seconds**).
    ///
    /// Convenience over [`Self::cursor_advance`] that owns BOTH the stream key
    /// ([`haven_core::relay::STREAM_GROUP_445`]) and the seconds→milliseconds
    /// conversion in one place, so the Dart caller passes a plain event
    /// timestamp and cannot drift the key or the unit. Monotonic-max: only ever
    /// moves the cursor forward.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the storage write fails.
    pub async fn cursor_advance_group_to_event(
        &self,
        event_created_at_secs: i64,
    ) -> Result<(), String> {
        let ms = event_secs_to_cursor_ms(event_created_at_secs);
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .advance_sync_cursor(haven_core::relay::STREAM_GROUP_445, ms)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Advances the `inbox_1059` cursor to a processed gift-wrap's `created_at`
    /// (Unix **seconds**).
    ///
    /// As [`Self::cursor_advance_group_to_event`], but for the gift-wrap inbox
    /// stream ([`haven_core::relay::STREAM_INBOX_1059`]). The 7-day inbox
    /// lookback applied at REQ time (see [`haven_core::relay::cursor`]) absorbs
    /// NIP-59's wrapper backdating, so advancing on the outer wrapper timestamp
    /// is safe.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string if the storage write fails.
    pub async fn cursor_advance_inbox_to_wrap(
        &self,
        wrap_created_at_secs: i64,
    ) -> Result<(), String> {
        let ms = event_secs_to_cursor_ms(wrap_created_at_secs);
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .advance_sync_cursor(haven_core::relay::STREAM_INBOX_1059, ms)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
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

    // NOTE (Dark Matter): `wipe_all_staged_commits` is RETIRED. The M7
    // staged-commit marker table is deleted — the engine owns pending-commit
    // durability via `EpochState::PendingPublish` / `PendingStateRef` /
    // `PendingCommitRecovered` on hydrate, so there is no Haven-side marker for
    // a returning identity to inherit. Logout wipes the whole `session.sqlite`.

    /// Prunes the gift-wrap dedup cache (`processed_gift_wraps`): drops rows
    /// past the retention window, then enforces the row cap. Returns the number
    /// of rows removed. Best-effort maintenance, safe to call on every poll
    /// cycle. `now_unix_secs` is the current Unix **seconds** clock. Errors are
    /// redacted.
    pub async fn prune_processed_gift_wraps(&self, now_unix_secs: i64) -> Result<u64, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .prune_processed_gift_wraps(now_unix_secs)
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
        })
        .await
    }

    /// Resets ALL sync cursors (bulk) for the wipe-on-logout path, so a
    /// returning identity re-seeds cleanly instead of resuming at a stale
    /// floor. Errors are redacted.
    pub async fn reset_all_sync_cursors(&self) -> Result<(), String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .reset_all_sync_cursors()
                .map_err(|e| haven_core::nostr::mls::redact_hex_sequences(&e.to_string()))
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
                // `Nip65` shares the persisted `KeyPackage` toggle (W2).
                RelayTypeFfi::Nip65 => inner.get_publish_kp_relay_list(),
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
                RelayTypeFfi::Nip65 => inner.set_publish_kp_relay_list(value),
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
        // Dark Matter W2: the recorded / on-wire kind is 10002 for Nip65, 10050
        // for Inbox (NOT the persisted-slot `to_kind()`, which is 10051 for the
        // KeyPackage slot).
        let wire_kind_u16 = relay_list_wire_kind(relay_type).as_u16();
        let inner = self.inner.clone();
        let own_pk = keys.public_key();

        // Read toggle + list + compute targets + the previous publication's
        // `created_at` all under one blocking dispatch.
        let prep: (bool, Vec<String>, Vec<String>, Option<i64>) = run_blocking(move || {
            let publish = match core_type {
                haven_core::circle::RelayType::Inbox => inner.get_publish_inbox_relay_list(),
                haven_core::circle::RelayType::KeyPackage => inner.get_publish_kp_relay_list(),
            }
            .map_err(|e| e.to_string())?;
            if !publish {
                return Ok::<(bool, Vec<String>, Vec<String>, Option<i64>), String>((
                    false,
                    Vec::new(),
                    Vec::new(),
                    None,
                ));
            }
            let user = inner
                .list_user_relays(core_type)
                .map_err(|e| e.to_string())?;
            let targets = haven_core::relay::dedup_relay_targets(&user);
            // The previous publication's `created_at` so the republish supersedes
            // it even on a same-second re-edit (NIP-01 replaceable-event
            // determinism — a `created_at` tie can otherwise keep the old list).
            let last_published_at = inner
                .last_published_event(wire_kind_u16, "", &own_pk)
                .map_err(|e| e.to_string())?
                .map(|r| r.published_at);
            Ok((true, user, targets, last_published_at))
        })
        .await?;

        let (publish_enabled, user_list, targets, last_published_at) = prep;
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

        let event = build_relay_list_event_for(
            relay_type,
            &keys,
            &user_list,
            Some(haven_core::relay::superseding_created_at(last_published_at)),
        )?;
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
        // W2: the on-wire kind is 10002 for Nip65, 10050 for Inbox.
        let wire_kind = relay_list_wire_kind(relay_type);
        let kind_u16 = wire_kind.as_u16();

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
        let replacement = build_relay_list_unpublish_for(relay_type, &keys, last_published_at)?;
        let replacement_json = serde_json::to_string(&replacement)
            .map_err(|e| format!("Failed to serialize replacement: {e}"))?;

        let deletion_json = match last_event {
            Some(record) => {
                let deletion =
                    haven_core::relay::build_nip09_deletion(&keys, record.event_id, wire_kind)
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

        // W2: probe/scrub the on-wire kind (10002 for Nip65, 10050 for Inbox).
        let wire_kind = relay_list_wire_kind(relay_type);
        let kind_u16 = wire_kind.as_u16();
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

        let deletion = haven_core::relay::build_nip09_deletion(&keys, record.event_id, wire_kind)
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
        let group_id = GroupId::from_slice(&mls_group_id);
        self.inner
            .group_epoch(&group_id)
            .await
            .map_err(|e| e.to_string())
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

// ==================== Profile (public Nostr metadata) ====================
//
// FFI wrappers for the owner-directed public-profile feature (kind-0 metadata +
// Blossom-hosted picture; docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §5). Every method
// is a thin pass-through: the business logic lives in `haven_core::profile::*`
// (where the Rust coverage gate applies) and the `CircleStorage` cache, reached
// through `CircleManager`'s profile pass-throughs. A `RelayManager` is built per
// network call (cheap, stateless — mirrors the profile integration tests). No
// picture URL ever crosses the FFI (plan D2) and no circle/group identifier is
// ever touched (plan §4.4).
//
// The whole surface — types AND methods — is one contiguous, banner-scoped
// region (its own top-level `impl CircleManagerFfi`) so the privacy CI guard
// (scripts/ci/check_profile_privacy_boundaries.sh) can scope its scan exactly.

use haven_core::profile::{
    blossom_server, build_blank_metadata_event, build_metadata_event, build_nip09_deletion,
    download_profile_picture, fetch_profiles, merge_edits, picture_sync_action,
    profile_read_relays, publish_metadata, resolve_write_relays, self_merge_base_relays,
    upload_profile_picture, CachedProfile, PictureSyncAction, ProfileEdits, ProfileMetadata,
    ProfileState, PROFILE_TTL_SECS,
};

/// Redacts hex sequences (>= 16 chars) from an error before it crosses the FFI.
///
/// Profile errors carry hex identifiers (pubkeys, event/blob hashes), so
/// [`haven_core::util::redact_hex_sequences`] scrubs them — no key material or
/// internal id reaches the Dart layer (Security Rules #6/#8, plan §4.4).
fn redact_profile_err(e: impl std::fmt::Display) -> String {
    haven_core::util::redact_hex_sequences(&e.to_string())
}

/// Returns the current Unix time in whole seconds, saturating (never negative).
fn profile_now_secs() -> i64 {
    i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX)
}

/// A member's public Nostr profile (kind-0 metadata), FFI-friendly.
///
/// Carries the resolved display fields plus `has_picture` (whether picture BYTES
/// are cached locally) and `is_known` (a kind-0 was resolved — possibly a blank
/// `{}`). It deliberately has **no picture URL field**: URLs never cross the FFI
/// (plan D2); Flutter renders bytes fetched via
/// [`CircleManagerFfi::get_profile_thumbnail`] /
/// [`CircleManagerFfi::get_profile_picture`].
#[derive(Clone)]
pub struct ProfileMetadataFfi {
    /// Profile owner's Nostr public key (hex).
    pub pubkey_hex: String,
    /// The same key in NIP-19 bech32 (`npub1...`), computed at the boundary.
    pub npub: String,
    /// kind-0 `display_name` (NIP-24), if present.
    pub display_name: Option<String>,
    /// kind-0 `name` (NIP-01), if present.
    pub name: Option<String>,
    /// kind-0 `about`, if present.
    pub about: Option<String>,
    /// Whether picture bytes are cached (a `profile_pictures` row exists).
    pub has_picture: bool,
    /// Whether a kind-0 was resolved (`true` even for a deliberately blank `{}`).
    pub is_known: bool,
    /// Unix seconds when this profile was last fetched (TTL base; `0` = never).
    pub fetched_at: i64,
}

/// Redacting `Debug`: `pubkey_hex`/`npub` are PUBLIC keys but, per Security Rule
/// #6 (no key material in logs), never printed in full — both pass through
/// `redact_hex_sequences` and the free-text display fields are elided.
impl std::fmt::Debug for ProfileMetadataFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProfileMetadataFfi")
            .field(
                "pubkey_hex",
                &haven_core::util::redact_hex_sequences(&self.pubkey_hex),
            )
            .field("npub", &haven_core::util::redact_hex_sequences(&self.npub))
            .field("display_name", &"<redacted>")
            .field("name", &"<redacted>")
            .field("about", &"<redacted>")
            .field("has_picture", &self.has_picture)
            .field("is_known", &self.is_known)
            .field("fetched_at", &self.fetched_at)
            .finish()
    }
}

impl ProfileMetadataFfi {
    /// Builds the FFI view from a cached profile row.
    ///
    /// `has_picture` is supplied by the caller (whether a `profile_pictures` row
    /// exists) since the picture bytes live in a separate table.
    fn from_cached(cached: &CachedProfile, has_picture: bool) -> Self {
        Self {
            pubkey_hex: cached.pubkey_hex.clone(),
            npub: hex_to_npub(&cached.pubkey_hex),
            display_name: cached.metadata.display_name().map(ToString::to_string),
            name: cached.metadata.name().map(ToString::to_string),
            about: cached.metadata.about().map(ToString::to_string),
            has_picture,
            is_known: cached.state == ProfileState::Known,
            fetched_at: cached.fetched_at,
        }
    }

    /// An `Unknown` placeholder for a pubkey with no resolved kind-0.
    fn unknown(pubkey_hex: String) -> Self {
        Self {
            npub: hex_to_npub(&pubkey_hex),
            pubkey_hex,
            display_name: None,
            name: None,
            about: None,
            has_picture: false,
            is_known: false,
            fetched_at: 0,
        }
    }
}

/// A reference to a stored profile picture (no bytes) returned after upload.
///
/// Flutter uses `pubkey_hex` to fetch the cached bytes and `sha256_hex` as a
/// decode-cache key; the picture URL never crosses the FFI (plan D2).
#[derive(Clone)]
pub struct ProfilePictureRefFfi {
    /// Owner's Nostr public key (hex).
    pub pubkey_hex: String,
    /// Hex SHA-256 of the uploaded (post-sanitization) bytes — the Blossom
    /// content address.
    pub sha256_hex: String,
}

/// Redacting `Debug`: neither the pubkey nor the content hash is printed in full
/// (Security Rules #6/#8).
impl std::fmt::Debug for ProfilePictureRefFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProfilePictureRefFfi")
            .field(
                "pubkey_hex",
                &haven_core::util::redact_hex_sequences(&self.pubkey_hex),
            )
            .field(
                "sha256_hex",
                &haven_core::util::redact_hex_sequences(&self.sha256_hex),
            )
            .finish()
    }
}

impl CircleManagerFfi {
    /// Resolves public profiles for the given member pubkeys, fetching stale or
    /// missing ones, and returns the merged set.
    ///
    /// Callers pass the UNION of member pubkeys across all circles (plan §1.7).
    /// With `force == false`, pubkeys whose cached row is still fresh within
    /// `PROFILE_TTL_SECS` are served from cache and never refetched. Fetched
    /// kind-0s are upserted; queried authors that return nothing are recorded as
    /// `Unknown`. `has_picture` reflects whether picture BYTES are cached.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on relay or database failure.
    pub async fn fetch_member_profiles(
        &self,
        pubkeys_hex: Vec<String>,
        force: bool,
    ) -> Result<Vec<ProfileMetadataFfi>, String> {
        let now = profile_now_secs();

        // Parse hex → PublicKey, dropping malformed ids (never fail the whole
        // batch on one bad entry). De-dup while preserving the caller's order.
        // Cache rows are keyed by canonical lowercase `PublicKey::to_hex()`, so
        // normalize the caller's hex to lowercase before dedup/query — otherwise
        // an uppercase input never matches its stored row (bug LOW-6).
        let mut all_hex: Vec<String> = Vec::with_capacity(pubkeys_hex.len());
        let mut parsed: Vec<(String, nostr::PublicKey)> = Vec::with_capacity(pubkeys_hex.len());
        for hex in pubkeys_hex {
            let hex = normalize_pubkey_hex(&hex);
            if all_hex.contains(&hex) {
                continue;
            }
            if let Ok(pk) = nostr::PublicKey::from_hex(&hex) {
                all_hex.push(hex.clone());
                parsed.push((hex, pk));
            }
        }
        if parsed.is_empty() {
            return Ok(Vec::new());
        }

        // Decide which need a network fetch: forced, uncached, or past TTL.
        let cached = self
            .inner
            .get_profiles(&all_hex)
            .map_err(redact_profile_err)?;
        let to_fetch: Vec<nostr::PublicKey> = parsed
            .iter()
            .filter(|(hex, _)| {
                if force {
                    return true;
                }
                match cached.iter().find(|c| &c.pubkey_hex == hex) {
                    // Fresh within TTL ⇒ serve from cache (skip). Otherwise refetch.
                    Some(c) => now.saturating_sub(c.fetched_at) >= PROFILE_TTL_SECS,
                    None => true,
                }
            })
            .map(|(_, pk)| *pk)
            .collect();

        if !to_fetch.is_empty() {
            let relay = haven_core::relay::RelayManager::new();
            let fetched = fetch_profiles(&relay, &to_fetch, &profile_read_relays(), now)
                .await
                .map_err(redact_profile_err)?;
            for cp in &fetched {
                // Newer-wins: a lagging relay must not downgrade a newer cached
                // row, and a forced refetch must not revert a just-published
                // optimistic edit (bug MEDIUM-3).
                self.inner
                    .upsert_profile_if_newer(cp)
                    .map_err(redact_profile_err)?;
            }
            // Authors that returned nothing → `Unknown` rows (suppress churn).
            let returned: std::collections::HashSet<&str> =
                fetched.iter().map(|c| c.pubkey_hex.as_str()).collect();
            let missing: Vec<String> = to_fetch
                .iter()
                .map(|pk| pk.to_hex())
                .filter(|h| !returned.contains(h.as_str()))
                .collect();
            self.inner
                .mark_profiles_unknown(&missing, now)
                .map_err(redact_profile_err)?;
        }

        // Re-read the merged set (fresh + previously-cached + newly-unknown).
        let merged = self
            .inner
            .get_profiles(&all_hex)
            .map_err(redact_profile_err)?;
        let mut out = Vec::with_capacity(merged.len());
        for cp in &merged {
            // `has_picture` means cached bytes exist AND their URL still equals
            // the current kind-0 `picture` URL — a changed/cleared URL reports
            // false so the Dart gate re-downloads/clears (bug HIGH-2).
            let has_picture = self
                .inner
                .has_current_picture(&cp.pubkey_hex, cp.metadata.picture())
                .map_err(redact_profile_err)?;
            out.push(ProfileMetadataFfi::from_cached(cp, has_picture));
        }
        Ok(out)
    }

    /// Reconciles a member's cached profile-picture bytes with their current
    /// kind-0 `picture` URL (authoritative; never driven by Dart).
    ///
    /// Reads the CURRENT `picture` URL from the cached kind-0 and the URL stored
    /// with any cached bytes, then (bug HIGH-2):
    /// * **URL present and changed / no bytes yet** → download + overwrite,
    ///   recording the new URL;
    /// * **URL absent/cleared but stale bytes cached** → delete the stale row so
    ///   a removed avatar stops rendering;
    /// * **URL unchanged** → no-op.
    ///
    /// This makes the Dart gate `if (!hasPicture) downloadMemberPicture(..)`
    /// correct for every transition: a changed URL → `has_picture` false →
    /// re-download; a removed URL → `has_picture` false → this call clears the
    /// row.
    ///
    /// The download applies the anti-SSRF connect-time IP filter and re-encodes
    /// (plan §4 blossom.rs); bytes are cached in SQLCipher; the URL never crosses
    /// the FFI (plan D2). Because the URL is read from the cached kind-0, an
    /// attacker-supplied Dart string can never drive the download target.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on download or database failure.
    pub async fn download_member_picture(&self, pubkey_hex: String) -> Result<(), String> {
        let Some(cached) = self
            .inner
            .get_profile(&pubkey_hex)
            .map_err(redact_profile_err)?
        else {
            return Ok(());
        };
        let current_url = cached.metadata.picture();
        let cached_url = self
            .inner
            .get_profile_picture_url(&pubkey_hex)
            .map_err(redact_profile_err)?;
        match picture_sync_action(current_url, cached_url.as_deref()) {
            PictureSyncAction::Skip => Ok(()),
            PictureSyncAction::Clear => self
                .inner
                .delete_profile_picture(&pubkey_hex)
                .map_err(redact_profile_err),
            PictureSyncAction::Download => {
                // `Download` implies a non-blank current URL. Store it verbatim
                // (not the reparsed descriptor URL) so a subsequent
                // `has_current_picture` comparison against the kind-0 matches
                // exactly and does not re-download in a loop.
                let Some(url) = current_url.map(ToString::to_string) else {
                    return Ok(());
                };
                let picture = download_profile_picture(&url)
                    .await
                    .map_err(redact_profile_err)?;
                let sha = hex::decode(&picture.sha256_hex).map_err(redact_profile_err)?;
                self.inner
                    .upsert_profile_picture(
                        &pubkey_hex,
                        &url,
                        &sha,
                        picture.canonical.as_slice(),
                        picture.thumbnail.as_slice(),
                        profile_now_secs(),
                    )
                    .map_err(redact_profile_err)?;
                Ok(())
            }
        }
    }

    /// Returns the locally cached profile for a pubkey, or `None`.
    ///
    /// Pure cache read (no network) — the synchronous hot path for member
    /// markers/tiles.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on database failure.
    #[frb(sync)]
    pub fn get_cached_profile(
        &self,
        pubkey_hex: String,
    ) -> Result<Option<ProfileMetadataFfi>, String> {
        let Some(cached) = self
            .inner
            .get_profile(&pubkey_hex)
            .map_err(redact_profile_err)?
        else {
            return Ok(None);
        };
        let has_picture = self
            .inner
            .has_current_picture(&pubkey_hex, cached.metadata.picture())
            .map_err(redact_profile_err)?;
        Ok(Some(ProfileMetadataFfi::from_cached(&cached, has_picture)))
    }

    /// Returns a member's cached profile-picture thumbnail bytes, or `None`.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on database failure.
    pub async fn get_profile_thumbnail(
        &self,
        pubkey_hex: String,
    ) -> Result<Option<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_profile_thumbnail(&pubkey_hex)
                .map(|opt| opt.map(|z| z.to_vec()))
                .map_err(redact_profile_err)
        })
        .await
    }

    /// Returns a member's cached full-resolution profile-picture bytes, or `None`.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on database failure.
    pub async fn get_profile_picture(&self, pubkey_hex: String) -> Result<Option<Vec<u8>>, String> {
        let inner = self.inner.clone();
        run_blocking(move || {
            inner
                .get_profile_picture(&pubkey_hex)
                .map(|opt| opt.map(|z| z.to_vec()))
                .map_err(redact_profile_err)
        })
        .await
    }

    /// Fetches the local user's OWN kind-0 by pubkey, caches it, and returns it.
    ///
    /// Reads need no signer (security review F7): the pubkey identifies the
    /// profile; no secret crosses the FFI. A missing kind-0 yields an `Unknown`
    /// result rather than an error (offline-tolerant, plan D7).
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on relay or database failure.
    pub async fn fetch_my_profile(&self, pubkey_hex: String) -> Result<ProfileMetadataFfi, String> {
        let own_pk = nostr::PublicKey::from_hex(&pubkey_hex)
            .map_err(|_| "Invalid pubkey_hex".to_string())?;
        // Canonical lowercase key (matches how fetched rows are keyed), so the
        // newer-wins gate and the winning-row re-read line up.
        let own_hex = own_pk.to_hex();
        let now = profile_now_secs();
        let relay = haven_core::relay::RelayManager::new();
        let fetched = fetch_profiles(&relay, &[own_pk], &profile_read_relays(), now)
            .await
            .map_err(redact_profile_err)?;
        if let Some(cp) = fetched.into_iter().next() {
            // Newer-wins: never let a lagging relay revert a newer cached row /
            // just-published optimistic edit (bug MEDIUM-3). Return the WINNING
            // row, which may be the kept cached one rather than this fetch.
            self.inner
                .upsert_profile_if_newer(&cp)
                .map_err(redact_profile_err)?;
            let winner = self
                .inner
                .get_profile(&own_hex)
                .map_err(redact_profile_err)?
                .unwrap_or(cp);
            let has_picture = self
                .inner
                .has_current_picture(&own_hex, winner.metadata.picture())
                .map_err(redact_profile_err)?;
            Ok(ProfileMetadataFfi::from_cached(&winner, has_picture))
        } else {
            self.inner
                .mark_profiles_unknown(std::slice::from_ref(&own_hex), now)
                .map_err(redact_profile_err)?;
            Ok(self
                .inner
                .get_profile(&own_hex)
                .map_err(redact_profile_err)?
                .map_or_else(
                    || ProfileMetadataFfi::unknown(own_hex.clone()),
                    |cp| ProfileMetadataFfi::from_cached(&cp, false),
                ))
        }
    }

    /// Publishes the local user's OWN public profile (fetch → merge → publish).
    ///
    /// Publishing is **unconditional** (public-by-default, owner-directed
    /// 2026-07-16): saving a profile publishes a public kind-0 immediately, with
    /// no consent gate — that this is public is disclosed to the user in
    /// onboarding and the Identity settings page (a UI concern). The latest
    /// kind-0 is fetched first so unknown fields written by other clients survive
    /// the edit; `display_name`/`about` follow `ProfileEdits` semantics (`None` =
    /// untouched, `Some("")` = clear).
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on relay or database failure.
    pub async fn publish_my_profile(
        &self,
        identity_secret_bytes: Vec<u8>,
        display_name: Option<String>,
        about: Option<String>,
    ) -> Result<ProfileMetadataFfi, String> {
        // Zeroize immediately so early-return paths don't leak secret bytes.
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let keys = nostr::Keys::new(
            nostr::SecretKey::from_slice(&identity_secret_bytes)
                .map_err(|e| format!("Invalid secret key: {e}"))?,
        );
        let own_pk = keys.public_key();
        let own_hex = own_pk.to_hex();
        let now = profile_now_secs();

        let relay = haven_core::relay::RelayManager::new();
        // Resolve write relays first so the merge base is fetched from read ∪
        // write: for a NIP-65 user whose write relays are disjoint from the
        // discovery plane, the freshest own kind-0 lives on the WRITE relays, and
        // reading the base from discovery alone would drop other clients' fields
        // (bug MEDIUM-4). Haven-only users fall back to discovery (unchanged).
        let write_relays = resolve_write_relays(&relay, &own_pk).await;
        // Fetch-latest so we merge onto the freshest object (never clobber fields
        // set by another client).
        let base_cp = fetch_profiles(
            &relay,
            &[own_pk],
            &self_merge_base_relays(&write_relays),
            now,
        )
        .await
        .map_err(redact_profile_err)?
        .into_iter()
        .next();
        // Floor the republished kind-0's `created_at` above the freshest one we
        // merged onto, so a same-second edit still deterministically supersedes
        // it under NIP-01 replaceable-event semantics (otherwise a peer's forced
        // re-fetch resolves the stale profile — the relay keeps the old event on
        // a `created_at` tie).
        let prev_created_at = base_cp
            .as_ref()
            .and_then(|cp| u64::try_from(cp.event_created_at).ok());
        let base = base_cp.map_or_else(ProfileMetadata::default, |cp| cp.metadata);
        let merged = merge_edits(
            &base,
            &ProfileEdits {
                display_name,
                about,
                picture: None,
            },
        );
        let event =
            build_metadata_event(&keys, &merged, prev_created_at).map_err(redact_profile_err)?;
        // Unconditional publish (public-by-default). `publish_metadata` is the
        // shared transport; the only precondition is a non-empty write-relay set.
        publish_metadata(&relay, &event, &write_relays)
            .await
            .map_err(redact_profile_err)?;

        // Optimistic cache + published-events record (enables NIP-09 + the
        // retraction gate `has_published_profile`).
        let cached = CachedProfile {
            pubkey_hex: own_hex,
            metadata: merged,
            state: ProfileState::Known,
            event_created_at: i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
            fetched_at: now,
        };
        self.inner
            .upsert_profile(&cached)
            .map_err(redact_profile_err)?;
        self.inner
            .record_published_event(0, "", &event.id, &own_pk, now)
            .map_err(redact_profile_err)?;
        let has_picture = self
            .inner
            .has_current_picture(&cached.pubkey_hex, cached.metadata.picture())
            .map_err(redact_profile_err)?;
        Ok(ProfileMetadataFfi::from_cached(&cached, has_picture))
    }

    /// Uploads the local user's OWN profile picture and publishes it.
    ///
    /// Publishing is **unconditional** (public-by-default, owner-directed
    /// 2026-07-16): the upload and kind-0 publish happen on save with no consent
    /// gate — disclosed to the user in onboarding and the Identity settings page
    /// (a UI concern). The picture is sanitized (EXIF/GPS stripped, re-encoded)
    /// inside `upload_profile_picture` BEFORE any public upload; the resulting
    /// URL is merged into the freshest kind-0 and published.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on upload, relay, or database failure.
    pub async fn upload_my_profile_picture(
        &self,
        identity_secret_bytes: Vec<u8>,
        raw: Vec<u8>,
    ) -> Result<ProfilePictureRefFfi, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        // Minimize the cleartext image lifetime on the FFI side: wipe on drop.
        let raw = zeroize::Zeroizing::new(raw);
        let keys = nostr::Keys::new(
            nostr::SecretKey::from_slice(&identity_secret_bytes)
                .map_err(|e| format!("Invalid secret key: {e}"))?,
        );
        let own_pk = keys.public_key();
        let own_hex = own_pk.to_hex();
        let now = profile_now_secs();

        let server = blossom_server()
            .parse::<url::Url>()
            .map_err(|e| format!("Invalid Blossom server URL: {e}"))?;
        let picture = upload_profile_picture(&keys, &server, &raw)
            .await
            .map_err(redact_profile_err)?;

        // Merge the resulting URL into the freshest kind-0 and publish.
        // Resolve write relays first so the base is fetched from read ∪ write —
        // otherwise a NIP-65 user's freshest kind-0 (on the write relays) is
        // missed and the merge could drop other clients' fields (bug MEDIUM-4).
        let relay = haven_core::relay::RelayManager::new();
        let write_relays = resolve_write_relays(&relay, &own_pk).await;
        let base_cp = fetch_profiles(
            &relay,
            &[own_pk],
            &self_merge_base_relays(&write_relays),
            now,
        )
        .await
        .map_err(redact_profile_err)?
        .into_iter()
        .next();
        // Floor the republished kind-0's `created_at` above the freshest one we
        // merged onto, so a same-second edit still deterministically supersedes
        // it under NIP-01 replaceable-event semantics (otherwise a peer's forced
        // re-fetch resolves the stale profile — the relay keeps the old event on
        // a `created_at` tie).
        let prev_created_at = base_cp
            .as_ref()
            .and_then(|cp| u64::try_from(cp.event_created_at).ok());
        let base = base_cp.map_or_else(ProfileMetadata::default, |cp| cp.metadata);
        let merged = merge_edits(
            &base,
            &ProfileEdits {
                picture: Some(picture.url.clone()),
                ..ProfileEdits::default()
            },
        );
        let event =
            build_metadata_event(&keys, &merged, prev_created_at).map_err(redact_profile_err)?;
        publish_metadata(&relay, &event, &write_relays)
            .await
            .map_err(redact_profile_err)?;

        // Cache the picture bytes + updated profile; record the publish.
        let sha = hex::decode(&picture.sha256_hex).map_err(redact_profile_err)?;
        self.inner
            .upsert_profile_picture(
                &own_hex,
                &picture.url,
                &sha,
                picture.canonical.as_slice(),
                picture.thumbnail.as_slice(),
                now,
            )
            .map_err(redact_profile_err)?;
        let cached = CachedProfile {
            pubkey_hex: own_hex.clone(),
            metadata: merged,
            state: ProfileState::Known,
            event_created_at: i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
            fetched_at: now,
        };
        self.inner
            .upsert_profile(&cached)
            .map_err(redact_profile_err)?;
        self.inner
            .record_published_event(0, "", &event.id, &own_pk, now)
            .map_err(redact_profile_err)?;
        Ok(ProfilePictureRefFfi {
            pubkey_hex: own_hex,
            sha256_hex: picture.sha256_hex,
        })
    }

    /// Removes the local user's OWN profile picture (retraction republish).
    ///
    /// A **no-op unless a profile was published** (`has_published_profile`) — a
    /// retraction must never mint a first public event for a pubkey that never
    /// published. Otherwise it clears the `picture` field on the freshest kind-0
    /// and republishes.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on relay or database failure.
    pub async fn remove_my_profile_picture(
        &self,
        identity_secret_bytes: Vec<u8>,
    ) -> Result<ProfileMetadataFfi, String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let keys = nostr::Keys::new(
            nostr::SecretKey::from_slice(&identity_secret_bytes)
                .map_err(|e| format!("Invalid secret key: {e}"))?,
        );
        let own_pk = keys.public_key();
        let own_hex = own_pk.to_hex();
        let now = profile_now_secs();

        // Retraction no-op gate: never mint a first public event for a pubkey
        // that never published a profile.
        if !self
            .inner
            .has_published_profile(&own_pk)
            .map_err(redact_profile_err)?
        {
            return Ok(self
                .inner
                .get_profile(&own_hex)
                .map_err(redact_profile_err)?
                .map_or_else(
                    || ProfileMetadataFfi::unknown(own_hex.clone()),
                    |cp| ProfileMetadataFfi::from_cached(&cp, false),
                ));
        }

        // Clear the `picture` field on the freshest kind-0 and republish.
        // Resolve write relays first so the base is fetched from read ∪ write and
        // a NIP-65 user's freshest kind-0 isn't missed (bug MEDIUM-4).
        let relay = haven_core::relay::RelayManager::new();
        let write_relays = resolve_write_relays(&relay, &own_pk).await;
        let base_cp = fetch_profiles(
            &relay,
            &[own_pk],
            &self_merge_base_relays(&write_relays),
            now,
        )
        .await
        .map_err(redact_profile_err)?
        .into_iter()
        .next();
        // Floor the republished kind-0's `created_at` above the freshest one we
        // merged onto, so a same-second edit still deterministically supersedes
        // it under NIP-01 replaceable-event semantics (otherwise a peer's forced
        // re-fetch resolves the stale profile — the relay keeps the old event on
        // a `created_at` tie).
        let prev_created_at = base_cp
            .as_ref()
            .and_then(|cp| u64::try_from(cp.event_created_at).ok());
        let base = base_cp.map_or_else(ProfileMetadata::default, |cp| cp.metadata);
        let merged = merge_edits(
            &base,
            &ProfileEdits {
                picture: Some(String::new()),
                ..ProfileEdits::default()
            },
        );
        let event =
            build_metadata_event(&keys, &merged, prev_created_at).map_err(redact_profile_err)?;
        publish_metadata(&relay, &event, &write_relays)
            .await
            .map_err(redact_profile_err)?;

        let cached = CachedProfile {
            pubkey_hex: own_hex.clone(),
            metadata: merged,
            state: ProfileState::Known,
            event_created_at: i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
            fetched_at: now,
        };
        self.inner
            .upsert_profile(&cached)
            .map_err(redact_profile_err)?;
        self.inner
            .record_published_event(0, "", &event.id, &own_pk, now)
            .map_err(redact_profile_err)?;
        // Drop the cached picture BYTES too — updating only the kind-0 row would
        // leave the old bytes in `profile_pictures`, so the removed avatar would
        // re-render from cache and persist across restart (bug HIGH-1).
        self.inner
            .delete_profile_picture(&own_hex)
            .map_err(redact_profile_err)?;
        Ok(ProfileMetadataFfi::from_cached(&cached, false))
    }

    /// Deletes the local user's OWN public profile (best-effort, plan D10).
    ///
    /// A **no-op unless a profile was published** (`has_published_profile`).
    /// Otherwise it republishes a blank kind-0, best-effort NIP-09-deletes the
    /// last published kind-0, and clears the local profile cache. The Blossom
    /// blob DELETE is deferred (no delete helper in the profile module;
    /// documented best-effort).
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on relay or database failure.
    pub async fn delete_my_public_profile(
        &self,
        identity_secret_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
        if identity_secret_bytes.len() != 32 {
            return Err("Invalid secret bytes length".to_string());
        }
        let keys = nostr::Keys::new(
            nostr::SecretKey::from_slice(&identity_secret_bytes)
                .map_err(|e| format!("Invalid secret key: {e}"))?,
        );
        let own_pk = keys.public_key();
        let now = profile_now_secs();

        // Retraction no-op gate: never publish a blank kind-0 / kind-5 for a
        // pubkey that never published a profile (no new public footprint).
        if !self
            .inner
            .has_published_profile(&own_pk)
            .map_err(redact_profile_err)?
        {
            return Ok(());
        }

        let relay = haven_core::relay::RelayManager::new();
        let write_relays = resolve_write_relays(&relay, &own_pk).await;

        // 1. Blank kind-0 republish (supersedes any prior profile). Floor its
        // `created_at` above the freshest kind-0 we know about — the newer of
        // (a) the relay's canonical own profile and (b) our local optimistic
        // cache — so the retraction supersedes even a concurrent OTHER-client
        // edit and even when the delete lands in the same second as the last
        // edit (replaceable-event determinism — otherwise the blank could tie and
        // the relay keep the old profile, so peers never see the deletion).
        let fetched_prev = fetch_profiles(
            &relay,
            &[own_pk],
            &self_merge_base_relays(&write_relays),
            now,
        )
        .await
        .ok()
        .and_then(|v| v.into_iter().next())
        .and_then(|cp| u64::try_from(cp.event_created_at).ok());
        let local_prev = self
            .inner
            .get_profile(&own_pk.to_hex())
            .ok()
            .flatten()
            .and_then(|cp| u64::try_from(cp.event_created_at).ok());
        let prev_created_at = [fetched_prev, local_prev].into_iter().flatten().max();
        let blank =
            build_blank_metadata_event(&keys, prev_created_at).map_err(redact_profile_err)?;
        publish_metadata(&relay, &blank, &write_relays)
            .await
            .map_err(redact_profile_err)?;

        // 2. Best-effort NIP-09 deletion of the last published kind-0.
        if let Some(last) = self
            .inner
            .last_published_event(0, "", &own_pk)
            .map_err(redact_profile_err)?
        {
            let deletion = build_nip09_deletion(&keys, last.event_id, nostr::Kind::Metadata)
                .map_err(redact_profile_err)?;
            // A deletion that no relay honors must not fail the whole op.
            let _ = publish_metadata(&relay, &deletion, &write_relays).await;
        }

        // Record the blank publish and clear local profile rows.
        self.inner
            .record_published_event(0, "", &blank.id, &own_pk, now)
            .map_err(redact_profile_err)?;
        self.inner.wipe_all_profiles().map_err(redact_profile_err)?;
        Ok(())
    }

    /// Sets or clears a member's local petname (contact `display_name`).
    ///
    /// A purely local override (plan D6): `Some(name)` sets it, `None` clears it.
    /// Existing contact `notes` are preserved. Never leaves the device.
    ///
    /// # Errors
    ///
    /// Returns a redacted error string on database failure.
    #[frb(sync)]
    pub fn set_local_nickname(
        &self,
        pubkey_hex: String,
        nickname: Option<String>,
    ) -> Result<(), String> {
        // Preserve any existing notes; only the display_name (petname) changes.
        let notes = self
            .inner
            .get_contact(&pubkey_hex)
            .map_err(redact_profile_err)?
            .and_then(|c| c.notes);
        self.inner
            .set_contact(&pubkey_hex, nickname.as_deref(), notes.as_deref())
            .map(|_| ())
            .map_err(redact_profile_err)
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

/// Opt in to dialing a loopback / emulator-host Blossom server for hermetic
/// public-profile E2E tests.
///
/// Forwards to [`haven_core::profile::allow_private_blossom_for_test`] (debug
/// builds) or returns an error in release builds. The profile-picture DOWNLOAD
/// path applies a connect-time anti-SSRF IP filter that rejects every private /
/// loopback address; without this opt-in a synthetic peer cannot fetch a
/// picture whose `picture` URL points at the hermetic Blossom
/// (`http://10.0.2.2:3000` on the Android emulator, `http://localhost:3000` on
/// the iOS simulator/host). Even with the opt-in installed only the loopback /
/// emulator-host allowlist (`127.0.0.1`, `::1`, `10.0.2.2`) is relaxed; every
/// other private range stays blocked. Intended to be called from a scenario's
/// `setUpAll`, alongside [`set_discovery_relays_for_test`] and
/// [`set_blossom_server_for_test`].
///
/// # Errors
///
/// * Returns an error if the opt-in has already been installed in this process
///   (`OnceLock` install-once semantics).
/// * In release builds this function is unreachable; the sibling stub always
///   returns an error.
#[cfg(debug_assertions)]
#[frb(sync)]
pub fn allow_private_blossom_for_test() -> Result<(), String> {
    haven_core::profile::allow_private_blossom_for_test()
}

/// Release-build stub for [`allow_private_blossom_for_test`]. Gated at the FFI
/// wrapper itself (in addition to the haven-core function it forwards to) so a
/// release binary contains no path that relaxes the anti-SSRF filter.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
#[frb(sync)]
pub fn allow_private_blossom_for_test() -> Result<(), String> {
    Err("allow_private_blossom_for_test is disabled in release builds".to_string())
}

/// Overrides the Blossom upload server for hermetic public-profile E2E tests.
///
/// Forwards to [`haven_core::profile::set_blossom_server_for_test`] (debug
/// builds) or returns an error in release builds. `upload_my_profile_picture`
/// reads the effective server via `haven_core::profile::blossom_server`, so
/// installing this override before the first upload points A's picture at the
/// hermetic Blossom instead of the production default. Intended to be called
/// once from a scenario's `setUpAll` with the `HAVEN_E2E_BLOSSOM_URL`
/// dart-define value.
///
/// # Errors
///
/// * Returns an error if `url` is empty.
/// * Returns an error if the override has already been installed in this
///   process (`OnceLock` install-once semantics).
/// * In release builds this function is unreachable; the sibling stub always
///   returns an error.
#[cfg(debug_assertions)]
#[frb(sync)]
pub fn set_blossom_server_for_test(url: String) -> Result<(), String> {
    haven_core::profile::set_blossom_server_for_test(url)
}

/// Release-build stub for [`set_blossom_server_for_test`]. Gated at the FFI
/// wrapper itself so a release binary can never redirect Blossom uploads away
/// from the hard-coded HTTPS default.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
#[frb(sync)]
pub fn set_blossom_server_for_test(_url: String) -> Result<(), String> {
    Err("set_blossom_server_for_test is disabled in release builds".to_string())
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

/// Presence-only result of an M7 receive-only catch-up sweep. All counters —
/// no group ids, coordinates, or secrets — so it is leak-free (Rule 4).
pub struct CatchupResultFfi {
    /// Circles whose relays were swept.
    pub circles_swept: u32,
    /// Events the engine applied / terminally handled (Dark Matter taxonomy:
    /// locations, commits, and state changes are all engine-internal now).
    pub events_applied: u32,
    /// Events the engine durably buffered for a FUTURE epoch (the cursor
    /// stopped so they are re-fetched + re-surfaced once the gap fills).
    pub events_deferred: u32,
    /// Per-circle group cursors advanced.
    pub cursors_advanced: u32,
    /// The deadline was reached before every bucket was swept.
    pub deadline_hit: bool,
    /// Relay fetches that returned no response / errored (never fatal).
    pub relay_errors: u32,
}

impl From<haven_core::relay::CatchupOutcome> for CatchupResultFfi {
    fn from(o: haven_core::relay::CatchupOutcome) -> Self {
        let c = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
        Self {
            circles_swept: c(o.circles_swept),
            events_applied: c(o.events_applied),
            events_deferred: c(o.events_deferred),
            cursors_advanced: c(o.cursors_advanced),
            deadline_hit: o.deadline_hit,
            relay_errors: c(o.relay_errors),
        }
    }
}

/// What an M8-2 `KeyPackage` maintenance tick did (FFI mirror of
/// [`haven_core::relay::maintenance::KpMaintenanceAction`]).
///
/// Fieldless / payload-free — no `d`, url, hex, or group id — so it is
/// leak-free by construction (Security Rule 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KpMaintenanceActionFfi {
    /// A live-material canonical `KeyPackage` was already reachable — no change.
    AlreadyHealthy,
    /// A stable `d` was seeded from an on-relay canonical this tick; no publish.
    SeededD,
    /// A `KeyPackage` was (re)published into a reused, tracked/seeded stable `d`.
    RepublishedStableD,
    /// A `KeyPackage` was published into a freshly-minted `d` (first-ever slot).
    RepublishedFreshD,
}

impl From<haven_core::relay::maintenance::KpMaintenanceAction> for KpMaintenanceActionFfi {
    fn from(a: haven_core::relay::maintenance::KpMaintenanceAction) -> Self {
        use haven_core::relay::maintenance::KpMaintenanceAction as A;
        match a {
            A::AlreadyHealthy => Self::AlreadyHealthy,
            A::SeededD => Self::SeededD,
            A::RepublishedStableD => Self::RepublishedStableD,
            A::RepublishedFreshD => Self::RepublishedFreshD,
        }
    }
}

/// Presence-only result of an M8-2 `KeyPackage` maintenance tick.
///
/// Counters + an action enum only — never a relay url, `d`, hex, or group id —
/// so it is leak-free (Security Rule 4/6). This is the shape the Dart
/// `MaintenanceScheduler` folds ticks into.
#[derive(Debug, Clone, Copy)]
pub struct KpMaintenanceOutcomeFfi {
    /// What the tick did.
    pub action: KpMaintenanceActionFfi,
    /// Own-relay canonical (kind 30443) events the probe observed (summed
    /// across responders).
    pub canonical_on_relays: u32,
    /// Responding own relays the probe reached this tick (non-responders
    /// excluded).
    pub responders_probed: u32,
    /// Responding + non-live relays this tick republished to.
    pub relays_healed: u32,
    /// Relay probes/publishes that errored (tallied, never fatal).
    pub relay_errors: u32,
}

impl From<haven_core::relay::maintenance::KpMaintenanceOutcome> for KpMaintenanceOutcomeFfi {
    fn from(o: haven_core::relay::maintenance::KpMaintenanceOutcome) -> Self {
        let c = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
        Self {
            action: o.action.into(),
            canonical_on_relays: c(o.canonical_on_relays),
            responders_probed: c(o.responders_probed),
            relays_healed: c(o.relays_healed),
            relay_errors: c(o.relay_errors),
        }
    }
}

/// What an M8-1 relay-list maintenance tick did for one category (FFI mirror of
/// [`haven_core::relay::maintenance::RelayListAction`]).
///
/// Fieldless / payload-free, so leak-free by construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayListActionFfi {
    /// Publishing is suppressed by the privacy toggle (or nothing configured).
    Suppressed,
    /// A current list was already reachable — no change.
    AlreadyCurrent,
    /// The list was (re)published to own relays this tick.
    Republished,
}

impl From<haven_core::relay::maintenance::RelayListAction> for RelayListActionFfi {
    fn from(a: haven_core::relay::maintenance::RelayListAction) -> Self {
        use haven_core::relay::maintenance::RelayListAction as A;
        match a {
            A::Suppressed => Self::Suppressed,
            A::AlreadyCurrent => Self::AlreadyCurrent,
            A::Republished => Self::Republished,
        }
    }
}

/// Presence-only per-category tally of an M8-1 relay-list maintenance tick.
#[derive(Debug, Clone, Copy)]
pub struct RelayListCategoryOutcomeFfi {
    /// What the tick did for this category.
    pub action: RelayListActionFfi,
    /// Responding own relays the probe reached this tick (non-responders
    /// excluded).
    pub responders_probed: u32,
    /// Responding + unhealthy relays this tick republished to.
    pub relays_healed: u32,
    /// Relay probes/publishes that errored (tallied, never fatal).
    pub relay_errors: u32,
}

impl From<haven_core::relay::maintenance::RelayListCategoryOutcome>
    for RelayListCategoryOutcomeFfi
{
    fn from(o: haven_core::relay::maintenance::RelayListCategoryOutcome) -> Self {
        let c = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
        Self {
            action: o.action.into(),
            responders_probed: c(o.responders_probed),
            relays_healed: c(o.relays_healed),
            relay_errors: c(o.relay_errors),
        }
    }
}

/// Presence-only result of an M8-1 relay-list maintenance tick (both
/// categories). Counters + action enums only — leak-free (Security Rule 4/6).
#[derive(Debug, Clone, Copy)]
pub struct RelayListMaintenanceOutcomeFfi {
    /// The inbox (kind 10050) category outcome.
    pub inbox: RelayListCategoryOutcomeFfi,
    /// The `KeyPackage` (kind 10051) category outcome.
    pub key_package: RelayListCategoryOutcomeFfi,
}

impl From<haven_core::relay::maintenance::RelayListMaintenanceOutcome>
    for RelayListMaintenanceOutcomeFfi
{
    fn from(o: haven_core::relay::maintenance::RelayListMaintenanceOutcome) -> Self {
        Self {
            inbox: o.inbox.into(),
            key_package: o.key_package.into(),
        }
    }
}

/// What an M8-4 subscription-health tick did (FFI mirror of
/// [`haven_core::relay::live_sync::HealthAction`]).
///
/// Fieldless / payload-free — no url, id, or hex — so it is leak-free by
/// construction (Security Rule 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubscriptionHealthActionFfi {
    /// No live engine session — the inert no-op that ships while the live-sync
    /// engine is off (`liveSyncEnabled == false`).
    EngineOff,
    /// The engine is running and every relay is connected — nothing to do.
    Healthy,
    /// A relay had dropped; every subscription was re-anchored at its cursor.
    Resubscribed,
}

impl From<haven_core::relay::live_sync::HealthAction> for SubscriptionHealthActionFfi {
    fn from(a: haven_core::relay::live_sync::HealthAction) -> Self {
        use haven_core::relay::live_sync::HealthAction as A;
        match a {
            A::EngineOff => Self::EngineOff,
            A::Healthy => Self::Healthy,
            A::Resubscribed => Self::Resubscribed,
        }
    }
}

/// Presence-only result of an M8-4 subscription-health maintenance tick.
///
/// Counters + an action enum only — never a relay url, group id, or pubkey — so
/// it is leak-free (Security Rule 4/6). This is the shape the Dart
/// `MaintenanceScheduler` folds ticks into.
#[derive(Debug, Clone, Copy)]
pub struct SubscriptionHealthOutcomeFfi {
    /// What the tick did.
    pub action: SubscriptionHealthActionFfi,
    /// Relays in the engine pool at check time (`0` when engine off).
    pub relays_total: u32,
    /// Relays still coming up at check time (`Initialized` / `Pending` /
    /// `Connecting`); `0` when engine off. Reported so a caller can tell "all
    /// healthy" from "some still connecting" — a transient state that never
    /// triggers a resubscribe.
    pub relays_still_connecting: u32,
    /// Relays found dropped at check time (`0` when engine off).
    pub relays_disconnected: u32,
}

impl From<haven_core::relay::live_sync::SubscriptionHealthOutcome>
    for SubscriptionHealthOutcomeFfi
{
    fn from(o: haven_core::relay::live_sync::SubscriptionHealthOutcome) -> Self {
        let c = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
        Self {
            action: o.action.into(),
            relays_total: c(o.relays_total),
            relays_still_connecting: c(o.relays_still_connecting),
            relays_disconnected: c(o.relays_disconnected),
        }
    }
}

/// Presence-only result of the one-time legacy KeyPackage retraction (F10a).
///
/// Counters only — no relay urls, event ids, or `d` values — so a derived
/// `Debug` is leak-free (Security Rule 4/6).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LegacyRetractionOutcomeFfi {
    /// `true` when the sentinel was already set (no work done this call).
    pub already_done: bool,
    /// Stale legacy kind-443 KeyPackage twins scrubbed (kind-5 deletions ACKed).
    pub legacy_443_scrubbed: u32,
    /// `true` when the kind-10051 KeyPackage-relay list was retracted (≥1 ACK).
    pub relay_list_retracted: bool,
    /// Relay probes / publishes that errored (tallied, never fatal).
    pub relay_errors: u32,
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

    /// Runs an M7 receive-only catch-up sweep over every visible circle.
    ///
    /// Best-effort + deadline-bounded; NEVER authors/merges/converges a commit.
    /// The Dark Matter engine owns convergence + publish-before-apply, so
    /// catch-up ingests through the single process-global session (Rule 14) and
    /// the old `MlsWriteGate` hand-off is gone. Returns a presence-only
    /// [`CatchupResultFfi`] (counters).
    pub async fn run_catchup_all_circles(
        &self,
        circle: &CircleManagerFfi,
        own_pubkey_hex: String,
        max_duration_secs: u64,
    ) -> Result<CatchupResultFfi, String> {
        let circle_mgr = circle.inner.clone();
        let own_pk = nostr::PublicKey::parse(&own_pubkey_hex)
            .map_err(|e| format!("invalid own pubkey: {e}"))?;
        let outcome = haven_core::relay::catchup::run_catchup_all_circles(
            &circle_mgr,
            &self.inner,
            &own_pk,
            max_duration_secs,
        )
        .await;
        Ok(CatchupResultFfi::from(outcome))
    }

    /// `KeyPackage` maintenance (Dark Matter DM-2b) — republish-if-missing into
    /// a stable NIP-33 `d` slot on the user's own NIP-65 relays. Also the
    /// FIRST-publish path (onboarding / login): a responding relay serving
    /// nothing + no tracked slot mints a fresh package.
    ///
    /// Dart-timer-driven (the identity secret lives only in Dart, Security Rule
    /// 9): the secret bytes are consumed per-call and zeroized. Fail-soft and
    /// idempotent — one tick of the periodic maintenance loop.
    ///
    /// Steps:
    /// 1. Derive `Keys`/pubkey from the secret bytes (zeroized after).
    /// 2. Probe the user's OWN NIP-65 relays (dedup'd, own-relays-only — never a
    ///    default union) for kind-30443 events authored by self.
    /// 3. Build the presence snapshot (`(d, event_id)` per responder) — under
    ///    Dark Matter a published 30443 is a last-resort package that never dies
    ///    on join, so the presence gate is pure relay presence of the tracked
    ///    stable slot (the M8-2 live-material gate is gone).
    /// 4. Decide via [`decide_kp_maintenance`]; on `SeedD` record the seed row;
    ///    on `Republish` reuse-or-mint the single kind-30443 event, publish to
    ///    OWN relays only (publish-first), record the row, and delete minted
    ///    material on a failed publish (mdk#160).
    ///
    /// Returns a presence-only [`KpMaintenanceOutcomeFfi`] (counters + enum).
    ///
    /// [`decide_kp_maintenance`]: haven_core::relay::maintenance::decide_kp_maintenance
    pub async fn maintain_key_package(
        &self,
        circle: &CircleManagerFfi,
        identity_secret_bytes: Vec<u8>,
    ) -> Result<KpMaintenanceOutcomeFfi, String> {
        use haven_core::relay::maintenance::{
            decide_kp_maintenance, KpMaintenanceAction, KpMaintenanceDecision,
            KpMaintenanceOutcome, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
        };

        let keys = keys_from_secret_bytes(identity_secret_bytes)?;
        let own_pk = keys.public_key();

        // Own NIP-65 (KeyPackage-discovery) relays only — no default union, no
        // discovery plane. Persisted under the `KeyPackage` slot (W2).
        let circle_mgr = circle.inner.clone();
        let own_relays: Vec<String> = run_blocking({
            let mgr = circle_mgr.clone();
            move || {
                let user = mgr
                    .list_user_relays(haven_core::circle::RelayType::KeyPackage)
                    .map_err(|e| e.to_string())?;
                Ok::<Vec<String>, String>(haven_core::relay::dedup_relay_targets(&user))
            }
        })
        .await?;

        if own_relays.is_empty() {
            log::debug!("[maintain_key_package] no KeyPackage relays configured; skipping");
            return Ok(KpMaintenanceOutcomeFfi::from(KpMaintenanceOutcome::no_op(
                0,
            )));
        }

        // PER-RELAY probe of OWN relays for kind-30443 authored by self, so a
        // PARTIAL drop (present on A, dropped from B) is visible + healed on B.
        let filter = nostr::Filter::new()
            .kind(nostr::Kind::Custom(30443))
            .author(own_pk)
            .limit(64);
        let mut relay_errors: usize = 0;
        let per_relay = match self.inner.fetch_events_per_relay(filter, &own_relays).await {
            Ok(v) => v,
            Err(e) => {
                // Fail-closed: a top-level probe error yields NO responders ⇒
                // decide_kp_maintenance returns NoOp.
                relay_errors += 1;
                log::debug!(
                    "[maintain_key_package] probe failed: {}",
                    haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                );
                Vec::new()
            }
        };

        // Build the snapshot from RESPONDING relays only (non-responders are
        // excluded structurally, C4). Each responder contributes `(d, event_id)`
        // per on-relay 30443 — no live-material verdict under Dark Matter.
        let mut responders: Vec<RelayKpPerRelay> = Vec::new();
        for outcome in &per_relay {
            if !outcome.responded {
                continue;
            }
            let canonical: Vec<RelayKpEntry> = outcome
                .events
                .iter()
                .map(|ev| RelayKpEntry {
                    d_tag: kp_event_d_tag(ev).unwrap_or_default(),
                    event_id: ev.id.to_hex(),
                })
                .collect();
            responders.push(RelayKpPerRelay {
                relay_url: outcome.relay_url.clone(),
                canonical,
            });
        }
        let responders_probed = responders.len();
        let canonical_on_relays: usize = responders.iter().map(|r| r.canonical.len()).sum();
        let snapshot = RelayKpSnapshot { responders };

        // Read the stored stable slot and decide.
        let stored_stable_d = run_blocking({
            let mgr = circle_mgr.clone();
            move || mgr.latest_canonical_d_tag().map_err(|e| e.to_string())
        })
        .await?;
        let decision = decide_kp_maintenance(&snapshot, stored_stable_d.as_deref());

        // Republished-relay tally, only non-zero on a successful Republish.
        let mut relays_healed: usize = 0;
        let action = match decision {
            KpMaintenanceDecision::NoOp => KpMaintenanceAction::AlreadyHealthy,
            KpMaintenanceDecision::SeedD { d } => {
                // Record the seed row (on-relay event id + `d`, EMPTY bytes)
                // BEFORE any future mint so stability holds from cycle 1. The
                // empty `key_package` marks "adopt but not-yet-minted": the next
                // republish tick mints fresh into this slot (heal reuse needs
                // non-empty tracked bytes). No publish this tick.
                let event_id = snapshot
                    .responders
                    .iter()
                    .flat_map(|r| r.canonical.iter())
                    .find(|e| e.d_tag == d)
                    .map(|e| e.event_id.clone())
                    .unwrap_or_default();
                let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(0);
                let seeded = run_blocking({
                    let mgr = circle_mgr.clone();
                    let d = d.clone();
                    move || {
                        mgr.record_published_key_package(
                            &haven_core::circle::PublishedKeyPackageRow {
                                event_id,
                                d_tag: d,
                                key_package: Vec::new(),
                                created_at: now,
                            },
                        )
                        .map_err(|e| e.to_string())
                    }
                })
                .await;
                if seeded.is_err() {
                    relay_errors += 1;
                }
                KpMaintenanceAction::SeededD
            }
            KpMaintenanceDecision::Republish {
                existing_d,
                targets,
            } => {
                let (act, healed) = self
                    .republish_key_package(
                        &circle_mgr,
                        &keys,
                        existing_d.as_deref(),
                        &targets,
                        &mut relay_errors,
                    )
                    .await?;
                relays_healed = healed;
                act
            }
        };

        Ok(KpMaintenanceOutcomeFfi::from(KpMaintenanceOutcome {
            action,
            canonical_on_relays,
            responders_probed,
            relays_healed,
            relay_errors,
        }))
    }

    /// Reuses-or-mints, signs, publishes (to the confirmed-drop TARGET relays
    /// only), and records a `KeyPackage` republish for
    /// [`Self::maintain_key_package`]. Publish-first: only after a relay write
    /// succeeds is the tracking row recorded; freshly-minted material that
    /// FAILS to publish is deleted (mdk#160) so a retry loop never leaks
    /// private init keys.
    ///
    /// `targets` is the responded-and-non-serving subset of the user's own
    /// relays (from [`KpMaintenanceDecision::Republish`]). When the tracked slot
    /// still holds the cached last-resort package bytes, HEAL by re-publishing
    /// the SAME bytes verbatim (no re-mint); otherwise MINT a fresh package into
    /// the slot (first publish / seed-handoff / rotation).
    ///
    /// [`KpMaintenanceDecision::Republish`]: haven_core::relay::maintenance::KpMaintenanceDecision::Republish
    async fn republish_key_package(
        &self,
        circle_mgr: &Arc<CoreCircleManager>,
        keys: &nostr::Keys,
        existing_d: Option<&str>,
        targets: &[String],
        relay_errors: &mut usize,
    ) -> Result<(haven_core::relay::maintenance::KpMaintenanceAction, usize), String> {
        use haven_core::relay::maintenance::{
            build_kp_maintenance_events, build_kp_maintenance_events_reusing, KpMaintenanceAction,
        };

        // Read the currently-tracked row (bytes + d) so we can (a) HEAL by reuse
        // when the slot matches and carries bytes, and (b) capture superseded
        // bytes to delete on a rotation (mdk#160).
        let tracked = run_blocking({
            let mgr = circle_mgr.clone();
            move || {
                mgr.latest_published_key_package()
                    .map_err(|e| e.to_string())
            }
        })
        .await?;

        // Reuse only when the tracked row is the SAME slot AND carries non-empty
        // cached bytes (a seed row has empty bytes → mint fresh instead).
        let reuse_bytes: Option<Vec<u8>> = match (&tracked, existing_d) {
            (Some(row), Some(d)) if row.d_tag == d && !row.key_package.is_empty() => {
                Some(row.key_package.clone())
            }
            _ => None,
        };
        let minted_fresh = reuse_bytes.is_none();

        let events = if let Some(bytes) = reuse_bytes {
            // HEAL: re-advertise the cached last-resort package into the same slot.
            let d = existing_d.unwrap_or_default().to_owned();
            build_kp_maintenance_events_reusing(keys, &bytes, targets, &d)
                .map_err(|e| format!("build (reuse) key package events: {e}"))?
        } else {
            // MINT: a fresh last-resort package into `existing_d` (or a new slot).
            // Reuses the single process-global session (Rule 14) via the manager.
            build_kp_maintenance_events(circle_mgr.session(), keys, targets, existing_d)
                .await
                .map_err(|e| format!("build (mint) key package events: {e}"))?
        };

        let event_id = events.event.id.to_hex();
        let d_tag = events.d_tag.clone();
        let kp_bytes = events.key_package.bytes().to_vec();

        // Publish-first to the TARGET relays only (targets ⊆ configured ⊆ own).
        let published = match self.inner.publish_event(&events.event, targets).await {
            Ok(_) => true,
            Err(e) => {
                *relay_errors += 1;
                log::debug!(
                    "[maintain_key_package] 30443 publish failed: {}",
                    haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                );
                false
            }
        };

        if published {
            // Record the single-row-per-slot tracking row (drops the prior row).
            let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(0);
            let record = run_blocking({
                let mgr = circle_mgr.clone();
                move || {
                    mgr.record_published_key_package(&haven_core::circle::PublishedKeyPackageRow {
                        event_id,
                        d_tag,
                        key_package: kp_bytes,
                        created_at: now,
                    })
                    .map_err(|e| e.to_string())
                }
            })
            .await;
            if record.is_err() {
                *relay_errors += 1;
            }

            // ROTATION cleanup (mdk#160): a fresh mint into a slot that held
            // DIFFERENT live material supersedes it — delete the old private
            // material so it does not accumulate. (No-op for a heal/reuse, a
            // first publish, or a seed-handoff row with empty bytes.)
            if minted_fresh {
                if let Some(row) = &tracked {
                    if !row.key_package.is_empty() && row.key_package != events.key_package.bytes()
                    {
                        let superseded =
                            haven_core::nostr::mls::types::KeyPackage::new(row.key_package.clone());
                        if let Err(e) = circle_mgr.delete_key_package(&superseded).await {
                            log::debug!(
                                "[maintain_key_package] superseded KP delete failed: {}",
                                haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                            );
                        }
                    }
                }
            }
        } else if minted_fresh {
            // FAILED publish of freshly-minted material: delete it so a retry
            // loop against a failing relay never leaks private init keys (mdk#160).
            if let Err(e) = circle_mgr.delete_key_package(&events.key_package).await {
                log::debug!(
                    "[maintain_key_package] minted-on-failure KP delete failed: {}",
                    haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                );
            }
        }

        let action = if minted_fresh {
            KpMaintenanceAction::RepublishedFreshD
        } else {
            KpMaintenanceAction::RepublishedStableD
        };
        // `relays_healed` = the target count only when the write succeeded.
        let healed = if published { targets.len() } else { 0 };
        Ok((action, healed))
    }

    /// Once-only legacy relay hygiene (Dark Matter §6 step 5 / F10a): retracts
    /// this account's stale pre-migration KeyPackage advertisements so an
    /// old-stack client cannot mint a Welcome the new stack can't process.
    ///
    /// NON-OPTIONAL cutover cleanup, guarded by a persisted sentinel
    /// (`legacy_kp_retraction_done`) so it fires at most once:
    /// 1. If the sentinel is already set → no-op (`already_done = true`).
    /// 2. Probe the user's OWN NIP-65 (KeyPackage-discovery) relays for their
    ///    own kind-443 KeyPackages AND their kind-10051 relay list.
    /// 3. For each 443, publish a self-authored NIP-09 (kind-5) id-only deletion
    ///    ([`build_legacy_key_package_retraction`]). For a present 10051, publish
    ///    an empty-replacement retraction ([`build_key_package_relay_list_retraction`])
    ///    plus a best-effort NIP-09 coordinate deletion.
    /// 4. On ≥1-relay ACK of ANY retraction, set the sentinel
    ///    ([`mark_legacy_kp_retraction_done`]) so it never re-runs.
    ///
    /// Dart-driven (the identity secret lives only in Dart, Rule 9); the secret
    /// bytes are consumed per-call and zeroized. Fail-soft: relay errors are
    /// tallied, never fatal. Returns a presence-only [`LegacyRetractionOutcomeFfi`].
    ///
    /// [`build_legacy_key_package_retraction`]: haven_core::relay::maintenance::build_legacy_key_package_retraction
    /// [`build_key_package_relay_list_retraction`]: haven_core::relay::maintenance::build_key_package_relay_list_retraction
    pub async fn retract_legacy_key_material(
        &self,
        circle: &CircleManagerFfi,
        identity_secret_bytes: Vec<u8>,
    ) -> Result<LegacyRetractionOutcomeFfi, String> {
        use haven_core::relay::maintenance::{
            build_key_package_relay_list_retraction, build_legacy_key_package_retraction,
        };

        let keys = keys_from_secret_bytes(identity_secret_bytes)?;
        let own_pk = keys.public_key();
        let own_hex = own_pk.to_hex();
        let circle_mgr = circle.inner.clone();

        // Sentinel gate: fire at most once.
        let done = run_blocking({
            let mgr = circle_mgr.clone();
            move || mgr.legacy_kp_retraction_done().map_err(|e| e.to_string())
        })
        .await?;
        if done {
            return Ok(LegacyRetractionOutcomeFfi {
                already_done: true,
                ..Default::default()
            });
        }

        let mut outcome = LegacyRetractionOutcomeFfi::default();

        // Own NIP-65 (KeyPackage-discovery) relays — where the stale 443/10051
        // were published. Own-relays-only, no default union.
        let own_relays: Vec<String> = run_blocking({
            let mgr = circle_mgr.clone();
            move || {
                let user = mgr
                    .list_user_relays(haven_core::circle::RelayType::KeyPackage)
                    .map_err(|e| e.to_string())?;
                Ok::<Vec<String>, String>(haven_core::relay::dedup_relay_targets(&user))
            }
        })
        .await?;
        if own_relays.is_empty() {
            // Nowhere to probe or publish; leave the sentinel UNSET so a later
            // call (once relays are configured) retries the cleanup.
            log::debug!("[retract_legacy] no KeyPackage relays configured; deferring");
            return Ok(outcome);
        }

        // Probe own relays for the account's legacy 443 KeyPackages and 10051
        // relay list (single merged filter over both kinds).
        let filter = nostr::Filter::new()
            .kinds([nostr::Kind::Custom(443), nostr::Kind::MlsKeyPackageRelays])
            .author(own_pk)
            .limit(64);
        let events = match self.inner.fetch_events(filter, &own_relays, None).await {
            Ok(v) => v,
            Err(e) => {
                outcome.relay_errors += 1;
                log::debug!(
                    "[retract_legacy] probe failed: {}",
                    haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                );
                Vec::new()
            }
        };

        let mut any_acked = false;

        // Scrub each stale legacy 443 by an id-only kind-5 deletion; track the
        // newest 10051 (created_at + id) for the relay-list retraction.
        let mut latest_10051: Option<(i64, nostr::EventId)> = None;
        for ev in &events {
            match ev.kind {
                nostr::Kind::Custom(443) => {
                    match build_legacy_key_package_retraction(&keys, &ev.id.to_hex(), &own_hex) {
                        Ok(deletion) => {
                            match self.inner.publish_event(&deletion, &own_relays).await {
                                Ok(_) => {
                                    outcome.legacy_443_scrubbed += 1;
                                    any_acked = true;
                                }
                                Err(e) => {
                                    outcome.relay_errors += 1;
                                    log::debug!(
                                        "[retract_legacy] 443 deletion publish failed: {}",
                                        haven_core::nostr::mls::redact_hex_sequences(
                                            &e.to_string()
                                        )
                                    );
                                }
                            }
                        }
                        Err(e) => log::debug!(
                            "[retract_legacy] 443 deletion build skipped: {}",
                            haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                        ),
                    }
                }
                nostr::Kind::MlsKeyPackageRelays => {
                    let at = i64::try_from(ev.created_at.as_secs()).unwrap_or(0);
                    if latest_10051.is_none_or(|(prev, _)| at >= prev) {
                        latest_10051 = Some((at, ev.id));
                    }
                }
                _ => {}
            }
        }

        // Retract the 10051 relay list if one was present: publish an empty
        // replaceable 10051 (superseding the last), plus a NIP-09 coordinate
        // deletion of the observed list for relays that honor NIP-09 over
        // replaceable supersession.
        if let Some((at, id)) = latest_10051 {
            match build_key_package_relay_list_retraction(&keys, Some(at)) {
                Ok(retraction) => {
                    match self.inner.publish_event(&retraction, &own_relays).await {
                        Ok(_) => {
                            outcome.relay_list_retracted = true;
                            any_acked = true;
                        }
                        Err(e) => {
                            outcome.relay_errors += 1;
                            log::debug!(
                                "[retract_legacy] 10051 retraction publish failed: {}",
                                haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                            );
                        }
                    }
                    // Best-effort coordinate deletion (never fatal).
                    if let Ok(deletion) = haven_core::relay::build_nip09_deletion(
                        &keys,
                        id,
                        nostr::Kind::MlsKeyPackageRelays,
                    ) {
                        let _ = self.inner.publish_event(&deletion, &own_relays).await;
                    }
                }
                Err(e) => log::debug!(
                    "[retract_legacy] 10051 retraction build skipped: {}",
                    haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                ),
            }
        }

        // Set the once-only sentinel only after ≥1 retraction ACKed, so a
        // fully-failed run retries next call (idempotent; NIP-09 twice is safe).
        if any_acked {
            let marked = run_blocking({
                let mgr = circle_mgr.clone();
                move || {
                    mgr.mark_legacy_kp_retraction_done()
                        .map_err(|e| e.to_string())
                }
            })
            .await;
            if marked.is_err() {
                outcome.relay_errors += 1;
            }
        }

        Ok(outcome)
    }

    /// M8-1 relay-list maintenance — republish-if-missing/drifted for the
    /// user's kind 10050 (inbox) + 10051 (`KeyPackage`) relay lists, honoring
    /// the per-category privacy toggle.
    ///
    /// Dart-timer-driven; the secret bytes are consumed per-call and zeroized
    /// (Security Rule 9). Fail-soft + idempotent.
    ///
    /// Per category: reads the user's OWN configured relays, NETWORK-PROBES the
    /// user's OWN relays for a currently-reachable list (never a local-timestamp
    /// check — a relay-side drop must be detected), and if missing/drifted
    /// republishes via [`build_relay_list_event`] + [`dedup_relay_targets`]
    /// (own relays only, no default union). When the toggle is off it skips (no
    /// publish). Never NIP-65/kind-10002 (Haven posture). `record_published_event`
    /// after a successful publish.
    ///
    /// Returns a presence-only [`RelayListMaintenanceOutcomeFfi`].
    ///
    /// [`build_relay_list_event`]: haven_core::relay::build_relay_list_event
    /// [`dedup_relay_targets`]: haven_core::relay::dedup_relay_targets
    pub async fn maintain_relay_list(
        &self,
        circle: &CircleManagerFfi,
        identity_secret_bytes: Vec<u8>,
    ) -> Result<RelayListMaintenanceOutcomeFfi, String> {
        use haven_core::relay::maintenance::RelayListMaintenanceOutcome;

        let (keys, own_pk) = {
            let identity_secret_bytes = zeroize::Zeroizing::new(identity_secret_bytes);
            if identity_secret_bytes.len() != 32 {
                return Err("Invalid secret bytes length".to_string());
            }
            let secret_key = nostr::SecretKey::from_slice(&identity_secret_bytes)
                .map_err(|e| format!("Invalid secret key: {e}"))?;
            let keys = nostr::Keys::new(secret_key);
            let pk = keys.public_key();
            (keys, pk)
        };

        let circle_mgr = circle.inner.clone();
        let inbox = self
            .maintain_relay_list_category(
                &circle_mgr,
                &keys,
                &own_pk,
                haven_core::circle::RelayType::Inbox,
            )
            .await;
        let key_package = self
            .maintain_relay_list_category(
                &circle_mgr,
                &keys,
                &own_pk,
                haven_core::circle::RelayType::KeyPackage,
            )
            .await;

        Ok(RelayListMaintenanceOutcomeFfi::from(
            RelayListMaintenanceOutcome { inbox, key_package },
        ))
    }

    /// Runs [`Self::maintain_relay_list`] for one category. Fail-soft: any
    /// error is tallied into `relay_errors`, never propagated.
    async fn maintain_relay_list_category(
        &self,
        circle_mgr: &Arc<CoreCircleManager>,
        keys: &nostr::Keys,
        own_pk: &nostr::PublicKey,
        relay_type: haven_core::circle::RelayType,
    ) -> haven_core::relay::maintenance::RelayListCategoryOutcome {
        use haven_core::relay::maintenance::{
            decide_relay_list, list_relay_healthy, RelayListAction, RelayListCategoryOutcome,
            RelayListDecision, RelayListPerRelay, RelayListSnapshot,
        };

        let mut relay_errors: usize = 0;

        // Toggle + configured relays (own-relays-only, dedup'd).
        let prep: Result<(bool, Vec<String>), String> = run_blocking({
            let mgr = circle_mgr.clone();
            move || {
                let enabled = match relay_type {
                    haven_core::circle::RelayType::Inbox => mgr.get_publish_inbox_relay_list(),
                    haven_core::circle::RelayType::KeyPackage => mgr.get_publish_kp_relay_list(),
                }
                .map_err(|e| e.to_string())?;
                let user = mgr
                    .list_user_relays(relay_type)
                    .map_err(|e| e.to_string())?;
                Ok((enabled, haven_core::relay::dedup_relay_targets(&user)))
            }
        })
        .await;
        let (publish_enabled, configured) = match prep {
            Ok(v) => v,
            Err(_) => {
                return RelayListCategoryOutcome {
                    action: RelayListAction::Suppressed,
                    responders_probed: 0,
                    relays_healed: 0,
                    relay_errors: 1,
                };
            }
        };

        // Fast-path suppression before any network probe.
        if !publish_enabled || configured.is_empty() {
            return RelayListCategoryOutcome::no_publish(RelayListAction::Suppressed);
        }

        // Dark Matter W2: the KeyPackage-discovery list is published as NIP-65
        // kind-10002 (`r` tags), the inbox list as kind-10050 (`relay` tags).
        let ffi_type = RelayTypeFfi::from(relay_type);
        let kind = relay_list_wire_kind(ffi_type);

        // PER-RELAY network probe of the user's OWN relays for a current list
        // (the wire kind authored by self). Unlike a merged fetch, this detects
        // a PARTIAL drop (present on A, dropped from B) so we can heal B only. A
        // top-level Err (e.g. URL validation) yields NO responders ⇒
        // decide_relay_list returns NoOp (fail-closed).
        let filter = nostr::Filter::new().kind(kind).author(*own_pk).limit(4);
        let per_relay = match self.inner.fetch_events_per_relay(filter, &configured).await {
            Ok(v) => v,
            Err(e) => {
                relay_errors += 1;
                log::debug!(
                    "[maintain_relay_list] probe failed: {}",
                    haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                );
                Vec::new()
            }
        };

        // Build responders-only verdicts. For each responding relay, the newest
        // (max created_at) self-authored list wins; an absent list ⇒ empty
        // on-relay set ⇒ unhealthy. Non-responders are excluded structurally.
        let mut responders: Vec<RelayListPerRelay> = Vec::new();
        for outcome in &per_relay {
            if !outcome.responded {
                continue;
            }
            let on_relay_urls = outcome
                .events
                .iter()
                .max_by_key(|e| e.created_at.as_secs())
                .map(|e| relay_list_urls_for(ffi_type, e))
                .unwrap_or_default();
            let healthy = list_relay_healthy(&on_relay_urls, &configured);
            responders.push(RelayListPerRelay {
                relay_url: outcome.relay_url.clone(),
                healthy,
            });
        }
        let responders_probed = responders.len();

        let snapshot = RelayListSnapshot {
            publish_enabled,
            responders,
            configured_relays: configured.clone(),
        };

        match decide_relay_list(&snapshot) {
            RelayListDecision::Suppressed => {
                RelayListCategoryOutcome::no_publish(RelayListAction::Suppressed)
            }
            RelayListDecision::NoOp => RelayListCategoryOutcome {
                action: RelayListAction::AlreadyCurrent,
                responders_probed,
                relays_healed: 0,
                relay_errors,
            },
            RelayListDecision::Republish { targets } => {
                // Floor the republish `created_at` above the previous publication
                // so it supersedes even when a maintenance cycle fires in the same
                // second as a manual edit whose event hasn't propagated to the
                // probed relays yet (NIP-01 replaceable-event determinism). A
                // failed lookup falls back to now() — no worse than before.
                let kind_u16 = kind.as_u16();
                let last_published_at = {
                    let cm = circle_mgr.clone();
                    let pk = own_pk.to_owned();
                    run_blocking(move || {
                        cm.last_published_event(kind_u16, "", &pk)
                            .map_err(|e| e.to_string())
                    })
                    .await
                    .ok()
                    .flatten()
                    .map(|r| r.published_at)
                };
                // The event CONTENT stays the FULL configured relay set (the
                // list always advertises all configured relays); only the
                // publish TARGET is the responded-and-unhealthy subset.
                let event = match build_relay_list_event_for(
                    ffi_type,
                    keys,
                    &configured,
                    Some(haven_core::relay::superseding_created_at(last_published_at)),
                ) {
                    Ok(ev) => ev,
                    Err(_) => {
                        return RelayListCategoryOutcome {
                            action: RelayListAction::Suppressed,
                            responders_probed,
                            relays_healed: 0,
                            relay_errors: relay_errors + 1,
                        };
                    }
                };
                let event_id = event.id;
                let created_at = i64::try_from(event.created_at.as_secs()).unwrap_or(0);

                match self.inner.publish_event(&event, &targets).await {
                    Ok(_) => {
                        let pk = *own_pk;
                        // Single per-kind published_events row (NOT per-relay):
                        // the replaceable list is one addressable event.
                        let rec = run_blocking({
                            let mgr = circle_mgr.clone();
                            move || {
                                mgr.record_published_event(kind_u16, "", &event_id, &pk, created_at)
                                    .map_err(|e| e.to_string())
                            }
                        })
                        .await;
                        if rec.is_err() {
                            relay_errors += 1;
                        }
                        RelayListCategoryOutcome {
                            action: RelayListAction::Republished,
                            responders_probed,
                            relays_healed: targets.len(),
                            relay_errors,
                        }
                    }
                    Err(e) => {
                        log::debug!(
                            "[maintain_relay_list] publish failed: {}",
                            haven_core::nostr::mls::redact_hex_sequences(&e.to_string())
                        );
                        RelayListCategoryOutcome {
                            action: RelayListAction::Suppressed,
                            responders_probed,
                            relays_healed: 0,
                            relay_errors: relay_errors + 1,
                        }
                    }
                }
            }
        }
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

    #[test]
    fn parse_engine_location_reads_content_json() {
        // The engine delivers the decrypted `LocationMessage` JSON on the stream;
        // the parse-helper reuses the Rust serde schema (M6-3). The fixture still
        // carries a legacy `display_name` key (as an OLD client emits) to pin
        // that the FFI parse tolerates it — new clients neither send nor surface
        // it (names come from public kind-0 profiles).
        let json = r#"{"latitude":1.5,"longitude":2.5,"geohash":"u4pruyd","timestamp":"2026-06-30T12:00:00Z","expires_at":"2026-06-30T12:15:00Z","display_name":"Alice"}"#;
        let sender = "AB".repeat(32); // 64 hex, mixed case
        let parsed = parse_engine_location(json.to_string(), sender).expect("parse");
        assert!((parsed.latitude - 1.5).abs() < f64::EPSILON);
        assert!((parsed.longitude - 2.5).abs() < f64::EPSILON);
        assert_eq!(parsed.geohash, "u4pruyd");
        assert!(
            !parsed.sender_pubkey.chars().any(|c| c.is_ascii_uppercase()),
            "sender pubkey must be normalized to lowercase"
        );
        assert!(parsed.timestamp > 0 && parsed.expires_at > parsed.timestamp);
    }

    #[test]
    fn parse_engine_location_rejects_invalid_content() {
        assert!(parse_engine_location("not json".to_string(), "ab".repeat(32)).is_err());
    }

    #[test]
    fn hex_to_npub_matches_known_vector() {
        // Canonical NIP-19 spec public key -> npub test vector (fixed, no rng).
        let hex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e";
        let npub = hex_to_npub(hex);
        assert!(npub.starts_with("npub1"));
        assert_eq!(
            npub,
            "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        );
    }

    #[test]
    fn hex_to_npub_falls_back_to_hex_on_invalid_input() {
        // Not valid hex/npub -> UI still gets a non-empty identifier.
        let bogus = "not-a-pubkey";
        assert_eq!(hex_to_npub(bogus), bogus);
    }

    #[test]
    fn circle_member_ffi_from_core_populates_npub() {
        let hex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e";
        let core = CoreCircleMember {
            pubkey: hex.to_string(),
            display_name: Some("Alice".to_string()),
            is_admin: true,
        };
        let ffi = CircleMemberFfi::from(&core);
        assert_eq!(ffi.pubkey, hex, "hex pubkey must be preserved unchanged");
        assert_eq!(
            ffi.npub,
            "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        );
        assert_eq!(ffi.display_name.as_deref(), Some("Alice"));
        assert!(ffi.is_admin);
    }

    #[test]
    fn circle_member_ffi_debug_redacts_keys_and_name() {
        // Mirrors the core `CircleMember` redacting Debug: neither the full hex
        // pubkey, the full npub, nor the local display name may appear in `{:?}`
        // output (Security Rule 6 defense-in-depth for public identifiers).
        let hex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e";
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg";
        let ffi = CircleMemberFfi::from(&CoreCircleMember {
            pubkey: hex.to_string(),
            display_name: Some("Alice".to_string()),
            is_admin: true,
        });
        let dbg = format!("{ffi:?}");

        // Full public keys must never be printed.
        assert!(
            !dbg.contains(hex),
            "debug output must not contain the full hex pubkey: {dbg}"
        );
        assert!(
            !dbg.contains(npub),
            "debug output must not contain the full npub: {dbg}"
        );
        // The local contact nickname must be elided, not dumped.
        assert!(
            !dbg.contains("Alice"),
            "debug output must not contain the display name: {dbg}"
        );

        // A truncated prefix (16 chars + ellipsis) must still be present for
        // both identifiers so the value is diagnosable without being complete.
        assert!(
            dbg.contains(&format!("{}...", &hex[..16])),
            "debug output must contain the truncated hex prefix: {dbg}"
        );
        assert!(
            dbg.contains(&format!("{}...", &npub[..16])),
            "debug output must contain the truncated npub prefix: {dbg}"
        );
        assert!(dbg.contains("is_admin: true"), "debug output: {dbg}");
    }

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

    /// Creates a fresh, unique temp directory for a filesystem test without a
    /// `tempfile` dev-dependency. Uses the pid + a monotonic counter so
    /// concurrent tests never collide. The dir (and everything under it) is
    /// removed on drop.
    struct ScratchDir(std::path::PathBuf);

    impl ScratchDir {
        fn new(tag: &str) -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let pid = std::process::id();
            let path = std::env::temp_dir().join(format!("haven_m10_{tag}_{pid}_{n}"));
            std::fs::create_dir_all(&path).expect("create scratch dir");
            Self(path)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// `delete_circles_db_files` removes the base file and every sidecar and is
    /// idempotent (a second call on already-gone files is a no-op).
    #[test]
    fn delete_circles_db_files_removes_base_and_sidecars_idempotently() {
        let dir = ScratchDir::new("circles_delete");
        let base = dir.path().join(CIRCLES_DB_FILENAME);
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = if suffix.is_empty() {
                base.clone()
            } else {
                std::path::PathBuf::from(format!("{}{suffix}", base.display()))
            };
            std::fs::write(&p, b"circles bytes").expect("seed file");
            assert!(p.exists());
        }

        let dir_str = dir.path().to_string_lossy().to_string();
        delete_circles_db_files(&dir_str).expect("deleting seeded files must succeed");

        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = if suffix.is_empty() {
                base.clone()
            } else {
                std::path::PathBuf::from(format!("{}{suffix}", base.display()))
            };
            assert!(!p.exists(), "'{suffix}' sidecar must be deleted");
        }

        // Idempotent: a second call on already-gone files is a success (Ok).
        delete_circles_db_files(&dir_str).expect("second delete on empty slate must be Ok");
    }

    // Migration note: the pre-Dark-Matter `delete_mdk_db_files` / `MDK_DB_FILENAME`
    // (`haven_mdk.db`) were split into `delete_mls_session_db_files` (the NEW
    // Dark Matter `session.sqlite` stack, wiped on logout) and
    // `delete_legacy_mls_db_files` (the legacy `haven_mdk.db`, deleted once at the
    // first-launch cutover). The base+sidecar deletion invariant is re-expressed
    // over BOTH successors below.

    /// `delete_mls_session_db_files` removes the Dark Matter session DB's base
    /// file + WAL/SHM/journal sidecars.
    #[test]
    fn delete_mls_session_db_files_removes_base_and_wal_sidecars() {
        let dir = ScratchDir::new("session_delete");
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = std::path::PathBuf::from(format!(
                "{}{suffix}",
                dir.path().join(MLS_SESSION_DB_FILENAME).display()
            ));
            std::fs::write(&p, b"session bytes").expect("seed file");
        }

        delete_mls_session_db_files(&dir.path().to_string_lossy())
            .expect("deleting seeded files must succeed");

        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = std::path::PathBuf::from(format!(
                "{}{suffix}",
                dir.path().join(MLS_SESSION_DB_FILENAME).display()
            ));
            assert!(
                !p.exists(),
                "session.sqlite '{suffix}' sidecar must be deleted"
            );
        }
    }

    /// `delete_legacy_mls_db_files` removes the PRE-Dark-Matter `haven_mdk.db`
    /// base file + WAL/SHM/journal sidecars — the file half of the one-time
    /// first-launch cutover cleanup (`destroy_legacy_mls_state`, whose keyring
    /// half needs a live backend). Idempotent on an already-gone slate.
    #[test]
    fn delete_legacy_mls_db_files_removes_base_and_wal_sidecars() {
        let dir = ScratchDir::new("legacy_delete");
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = std::path::PathBuf::from(format!(
                "{}{suffix}",
                dir.path().join(LEGACY_MLS_DB_FILENAME).display()
            ));
            std::fs::write(&p, b"legacy mdk bytes").expect("seed file");
        }

        delete_legacy_mls_db_files(&dir.path().to_string_lossy())
            .expect("deleting seeded legacy files must succeed");

        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = std::path::PathBuf::from(format!(
                "{}{suffix}",
                dir.path().join(LEGACY_MLS_DB_FILENAME).display()
            ));
            assert!(!p.exists(), "legacy '{suffix}' sidecar must be deleted");
        }

        // Idempotent: a second delete on the empty slate is a success (Ok).
        delete_legacy_mls_db_files(&dir.path().to_string_lossy())
            .expect("second legacy delete on empty slate must be Ok");
    }

    /// After wiping the circles.db file, a fresh open at the same path yields an
    /// EMPTY schema (no residual circle rows) — proving the wipe removes the
    /// data, not just the handle.
    #[test]
    fn fresh_circle_storage_after_file_wipe_has_empty_schema() {
        use haven_core::circle::CircleStorage;

        let dir = ScratchDir::new("circles_fresh");
        let db_path = dir.path().join(CIRCLES_DB_FILENAME);

        // Populate one circle, then drop the handle so the connection closes.
        {
            let storage = CircleStorage::new(&db_path, None).expect("open db");
            let circle = haven_core::circle::Circle {
                mls_group_id: haven_core::nostr::mls::types::GroupId::from_slice(&[7u8; 32]),
                nostr_group_id: [7u8; 32],
                display_name: "Wipe Me".to_string(),
                circle_type: haven_core::circle::CircleType::LocationSharing,
                relays: vec!["wss://relay.test".to_string()],
                created_at: 1,
                updated_at: 1,
            };
            storage.save_circle(&circle).expect("save circle");
            assert_eq!(storage.get_all_circles().expect("list").len(), 1);
        }

        // Wipe the file (+ sidecars), then re-open at the SAME path.
        delete_circles_db_files(&dir.path().to_string_lossy()).expect("wipe seeded circles.db");
        assert!(!db_path.exists(), "circles.db must be gone after wipe");

        let storage = CircleStorage::new(&db_path, None).expect("re-open db");
        assert_eq!(
            storage.get_all_circles().expect("list").len(),
            0,
            "a fresh open after wipe must have an empty schema"
        );
    }

    /// `remove_circles_db_key` and `remove_mls_session_db_key` are idempotent:
    /// calling them when no entry exists is a no-op (never panics/errs). Requires
    /// a live keyring backend to exercise the real delete path.
    #[test]
    #[ignore = "requires a running keyring backend (D-Bus Secret Service on Linux)"]
    fn remove_db_keys_are_idempotent() {
        // Two consecutive removals must both be no-op-safe (Ok) even if the
        // entry is already absent — "already gone" is success, not an error.
        remove_circles_db_key().expect("first circles key removal must be Ok");
        remove_circles_db_key().expect("second circles key removal (already gone) must be Ok");
        remove_mls_session_db_key().expect("first session key removal must be Ok");
        remove_mls_session_db_key().expect("second session key removal (already gone) must be Ok");
    }

    // ========================================================================
    // M10 logout wipe — end-to-end against a REAL manager-created DB + keyring
    // ========================================================================

    /// Whether a keyring entry currently holds a secret. `Ok(true)` means the
    /// key is present; `Err(NoEntry)` (mapped to `false`) means it was deleted
    /// or never created. Never returns or logs the secret bytes.
    fn keyring_key_present(service: &str, key_id: &str) -> bool {
        keyring_core::Entry::new(service, key_id)
            .ok()
            .is_some_and(|entry| entry.get_secret().is_ok())
    }

    /// Runs the async [`wipe_all_mls_state`] to completion on a private
    /// current-thread runtime. `wipe_all_mls_state` dispatches its filesystem
    /// and keyring work onto `spawn_blocking`, which requires a live tokio
    /// runtime; a dedicated one keeps the test self-contained.
    fn run_wipe(data_dir: &str) {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build current-thread runtime for wipe");
        rt.block_on(wipe_all_mls_state(data_dir.to_string()))
            .expect("wipe_all_mls_state must not error");
    }

    /// A generic 32-byte identity secret for constructing a real
    /// `CircleManagerFfi` under test. The Dark Matter session binds the device
    /// identity as a HARD construction requirement (DM-4), so `new` now demands
    /// the secret bytes; the keys never touch a real network here.
    fn wipe_test_secret_bytes() -> Vec<u8> {
        nostr::Keys::generate()
            .secret_key()
            .to_secret_bytes()
            .to_vec()
    }

    /// Drives one full M10 wipe end-to-end against a REAL `CircleManagerFfi`:
    /// the manager actually creates `circles.db` + `session.sqlite` on disk and
    /// provisions BOTH SQLCipher keys in whatever keyring backend is installed.
    /// The wipe must then delete every DB file + sidecar AND remove both keyring
    /// keys, and be safe to call a second time on the now-empty slate.
    ///
    /// Parameterized on the backend so the same body serves both the
    /// non-ignored in-memory-keyring run (proves file + key deletion in the
    /// sandbox) and the `#[ignore]`d real-OS-keyring run (proves the same
    /// against D-Bus Secret Service / Keychain on a keyring-enabled machine).
    fn assert_wipe_deletes_real_manager_state() {
        // Serialize with EVERY test that creates a `CircleManagerFfi` / touches
        // the shared keyring key-ids (M10 wipe tests + maintenance_real_ffi tc*)
        // so a concurrent create cannot re-provision a key between this wipe and
        // its "key absent" assertion. This fn is only ever called from a plain
        // `#[test]` (no ambient runtime), so `blocking_lock` cannot panic.
        let _guard = super::SHARED_KEYRING_TEST_LOCK.blocking_lock();

        // Clean slate: a prior aborted run (or another test) may have left the
        // shared keyring keys behind. Removing them first makes the "present
        // after create" assertions meaningful rather than coincidental.
        let _ = remove_circles_db_key();
        let _ = remove_mls_session_db_key();

        let dir = ScratchDir::new("wipe_e2e");
        let data_dir = dir.path().to_string_lossy().to_string();
        let circles_db = dir.path().join(CIRCLES_DB_FILENAME);
        let session_db = dir.path().join(MLS_SESSION_DB_FILENAME);

        // --- 1. Create a REAL manager: this mints both DB files + both keys. ---
        {
            let manager = CircleManagerFfi::new(data_dir.clone(), wipe_test_secret_bytes())
                .expect("CircleManagerFfi::new must create real MLS + circle DBs");
            // Hold the handle only long enough to prove the files/keys landed,
            // then drop it so both SQLite connections close before the wipe.
            drop(manager);
        }

        // --- 2. Files must exist on disk after creation. ---
        assert!(
            circles_db.exists(),
            "circles.db must exist after CircleManagerFfi::new"
        );
        assert!(
            session_db.exists(),
            "session.sqlite must exist after CircleManagerFfi::new"
        );

        // --- 3. Both keyring keys must exist after creation. ---
        assert!(
            keyring_key_present(CIRCLES_DB_SERVICE, CIRCLES_DB_KEY_ID),
            "circles.db keyring key must exist after manager creation"
        );
        assert!(
            keyring_key_present(CIRCLES_DB_SERVICE, MLS_SESSION_DB_KEY_ID),
            "session.sqlite keyring key must exist after manager creation"
        );

        // --- 4. Call the REAL wipe. ---
        run_wipe(&data_dir);

        // --- 5a. Every DB file + sidecar must be gone. ---
        for base in [&circles_db, &session_db] {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let p = if suffix.is_empty() {
                    base.clone()
                } else {
                    std::path::PathBuf::from(format!("{}{suffix}", base.display()))
                };
                assert!(
                    !p.exists(),
                    "'{}{suffix}' must be deleted by wipe_all_mls_state",
                    base.file_name().and_then(|n| n.to_str()).unwrap_or("db")
                );
            }
        }

        // --- 5b. Both keyring keys must be removed. ---
        assert!(
            !keyring_key_present(CIRCLES_DB_SERVICE, CIRCLES_DB_KEY_ID),
            "circles.db keyring key must be removed by wipe"
        );
        assert!(
            !keyring_key_present(CIRCLES_DB_SERVICE, MLS_SESSION_DB_KEY_ID),
            "session.sqlite keyring key must be removed by wipe"
        );

        // --- 6. Idempotent: a second wipe on the empty slate must not panic
        // and must leave everything absent (M10.1 retries the wipe on relaunch).
        run_wipe(&data_dir);
        assert!(
            !circles_db.exists(),
            "circles.db still absent after 2nd wipe"
        );
        assert!(
            !session_db.exists(),
            "session.sqlite still absent after 2nd wipe"
        );
        assert!(
            !keyring_key_present(CIRCLES_DB_SERVICE, CIRCLES_DB_KEY_ID),
            "circles.db key still absent after 2nd wipe"
        );
        assert!(
            !keyring_key_present(CIRCLES_DB_SERVICE, MLS_SESSION_DB_KEY_ID),
            "session.sqlite key still absent after 2nd wipe"
        );
    }

    /// M10 (non-ignored): proves `wipe_all_mls_state` deletes a REAL
    /// manager-created `circles.db` + `session.sqlite` (files + WAL/SHM/journal
    /// sidecars) AND removes both SQLCipher keyring keys — end-to-end, using the
    /// in-memory keyring backend so it runs in headless sandboxes/CI without a
    /// D-Bus Secret Service. This is the coverage a prior security review flagged
    /// as missing: Dart unit tests cannot reach `CircleManagerFfi::new`, so only
    /// a Rust test can prove the native manager's on-disk + keyring state is
    /// actually erased by the logout wipe.
    #[test]
    #[cfg(debug_assertions)]
    fn m10_wipe_deletes_real_manager_state_in_memory_keyring() {
        // Install the process-wide in-memory keyring BEFORE creating the
        // manager. Idempotent and a no-op if a backend is already installed.
        use_in_memory_keyring_for_test().expect("install in-memory keyring");
        assert_wipe_deletes_real_manager_state();
    }

    /// M10 (`#[ignore]`d): identical end-to-end assertion against the REAL OS
    /// keyring (D-Bus Secret Service on Linux, Keychain on macOS, Credential
    /// Manager on Windows). Gated because the sandbox/headless CI has no session
    /// keyring; run with `--ignored` on a keyring-enabled machine to prove the
    /// wipe erases keys from the genuine platform credential store, not just the
    /// mock. Do NOT combine in one process with the in-memory variant: the two
    /// keyring backends are mutually exclusive per process.
    #[test]
    #[ignore = "requires a running keyring backend (D-Bus Secret Service on Linux)"]
    fn m10_wipe_deletes_real_manager_state_os_keyring() {
        // Uses the real platform keyring via CircleManagerFfi::new's own
        // init_keyring_store(); do NOT install the in-memory backend here.
        assert_wipe_deletes_real_manager_state();
    }

    /// M10.1 crash-safety: a GENUINE (non-"already gone") teardown failure must
    /// be SURFACED as `Err`, not swallowed. Without this, the Dart logout would
    /// think the wipe succeeded, clear its durable retry marker, and never
    /// retry — leaving a decryptable DB / keyring key at rest (the "storage
    /// error" case M10.1 exists to survive).
    ///
    /// Injection: place a DIRECTORY where the `circles.db` FILE is expected, so
    /// `std::fs::remove_file` fails with a non-`NotFound` error (a genuine
    /// failure), while every other step is an already-clean no-op. The wipe must
    /// return `Err`, and the message must stay opaque (no path/filename leak).
    #[test]
    #[cfg(debug_assertions)]
    fn m10_wipe_surfaces_a_genuine_delete_failure() {
        // Share the keyring key-ids with the other M10 / tc* tests; this fn runs
        // under no ambient runtime (`#[test]`), so `blocking_lock` cannot panic.
        let _guard = super::SHARED_KEYRING_TEST_LOCK.blocking_lock();
        use_in_memory_keyring_for_test().expect("install in-memory keyring");

        let dir = ScratchDir::new("wipe_fail");
        let blocker = dir.path().join(CIRCLES_DB_FILENAME);
        // A directory at the circles.db path makes `remove_file` fail with a
        // genuine (EISDIR / non-NotFound) error.
        std::fs::create_dir(&blocker).expect("create blocking dir at circles.db path");

        let data_dir = dir.path().to_string_lossy().to_string();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build runtime for wipe");
        let result = rt.block_on(wipe_all_mls_state(data_dir));

        assert!(
            result.is_err(),
            "a genuine (non-NotFound) delete failure must be surfaced, not swallowed"
        );
        // Opaque: the surfaced error must not leak the path / filename (Security).
        let msg = result.unwrap_err();
        assert!(
            !msg.contains(CIRCLES_DB_FILENAME) && !msg.to_lowercase().contains("circles"),
            "wipe error must be generic/opaque (no path or filename leak)"
        );

        // Remove the blocker so ScratchDir::drop (remove_dir_all) is unhampered.
        let _ = std::fs::remove_dir_all(&blocker);
    }

    // ===== Decrypt-result folding — Dark Matter five-variant taxonomy =====
    //
    // The pre-migration `DecryptResultFfi` / `DecryptOutcomeFfi` /
    // `DecryptOutcomeKindFfi` types — with their `Unprocessable` /
    // `PreviouslyFailed` variants and the `flatten_outcome_to_legacy` compat shim
    // — were DELETED in the Dark Matter migration: stale / duplicate /
    // out-of-order handling is now entirely engine-internal, so the FFI surfaces
    // only the five application-visible `LocationMessageResult` variants via the
    // pure `convert_location_result` → `LocationMessageResultFfi` fold (no MDK /
    // no async / no live manager). The tests below re-express the surviving
    // conversion + redaction invariants over that new taxonomy, and add the
    // three new-in-Dark-Matter variants (Joined / Invalidated / Unrecoverable)
    // the old `Unprocessable`/`PreviouslyFailed` surfacing tests are replaced by.

    fn sample_location_content() -> String {
        // A real, parseable LocationMessage payload (same shape decrypt emits).
        let msg = haven_core::location::LocationMessage::new(37.7749295, -122.4194155);
        serde_json::to_string(&msg).expect("LocationMessage serializes")
    }

    /// A decrypted `Location` populates the FFI location, threads its MLS epoch
    /// through, and normalizes the sender pubkey to lowercase (so the Dart
    /// self-compare against the cached own pubkey is case-insensitive).
    #[test]
    fn convert_location_populates_location_and_normalizes_sender() {
        let result = haven_core::nostr::mls::types::LocationMessageResult::Location {
            sender_pubkey: "ABCDEF0123".to_string(),
            content: sample_location_content(),
            group_id: haven_core::nostr::mls::types::GroupId::from_slice(&[9]),
            epoch: 7,
        };
        let outcome = convert_location_result(result);
        assert_eq!(outcome.kind, LocationMessageResultKindFfi::Location);
        assert_eq!(outcome.epoch, 7, "epoch threads through for Location");
        assert_eq!(outcome.mls_group_id, vec![9]);
        let loc = outcome.location.expect("location present");
        assert_eq!(
            loc.sender_pubkey, "abcdef0123",
            "sender normalized lowercase"
        );
    }

    /// Wire-compat (plan D8 / protocol review 4.3): a decrypted `Location` whose
    /// content does NOT parse as a `LocationMessage` (e.g. a legacy
    /// `haven-avatar-*` inner from a pre-migration client) must still surface as
    /// `kind: Location, location: None` — decrypt succeeded at the MLS layer, so
    /// the caller advances past it exactly like a `GroupUpdate` (it must never
    /// treat a successfully-decrypted event as a retriable decrypt failure that
    /// gets reprocessed forever). Companion to
    /// `haven_avatar_inner_kind9_from_old_client_ignored_without_state_damage`
    /// in `haven-core/src/circle/manager.rs`, which pins the core-level
    /// `decrypt_location` half of this contract. (Under the new taxonomy the fold
    /// is infallible — it returns `LocationMessageResultFfi` directly, not a
    /// `Result` — so "never an Err on parse failure" is now structural.)
    #[test]
    fn convert_location_with_unparseable_content_is_seen_not_dropped() {
        let result = haven_core::nostr::mls::types::LocationMessageResult::Location {
            sender_pubkey: "ABCDEF0123".to_string(),
            content: r#"{"type":"haven-avatar-chunk","v":1,"version":1,"index":1,"data":"AAAA"}"#
                .to_string(),
            group_id: haven_core::nostr::mls::types::GroupId::from_slice(&[9]),
            epoch: 3,
        };
        let outcome = convert_location_result(result);
        assert_eq!(
            outcome.kind,
            LocationMessageResultKindFfi::Location,
            "decrypt succeeded at the MLS layer — kind stays Location"
        );
        assert!(
            outcome.location.is_none(),
            "unparseable content must not fabricate a location"
        );
    }

    /// Every NON-Location variant folds to its matching FFI kind, carries the
    /// local MLS group id (never published; Rule 4) through, has no location, and
    /// reports epoch 0 (the epoch is meaningful only for `Location`). Pins the
    /// full Dark Matter five-variant mapping so a new core variant cannot
    /// silently misfold. `Joined` / `Invalidated` / `Unrecoverable` are new
    /// Dark Matter outcomes with no pre-migration equivalent (they replace the
    /// deleted `Unprocessable` / `PreviouslyFailed` surfacing tests).
    #[test]
    fn convert_non_location_variants_map_and_carry_group_id() {
        use haven_core::nostr::mls::types::{GroupId, LocationMessageResult as R};
        let gid = GroupId::from_slice(&[7, 7, 7]);
        let cases = [
            (
                R::Joined {
                    group_id: gid.clone(),
                },
                LocationMessageResultKindFfi::Joined,
            ),
            (
                R::GroupUpdate {
                    group_id: gid.clone(),
                },
                LocationMessageResultKindFfi::GroupUpdate,
            ),
            (
                R::Invalidated {
                    group_id: gid.clone(),
                },
                LocationMessageResultKindFfi::Invalidated,
            ),
            (
                R::Unrecoverable {
                    group_id: gid.clone(),
                },
                LocationMessageResultKindFfi::Unrecoverable,
            ),
        ];
        for (result, expected) in cases {
            let outcome = convert_location_result(result);
            assert_eq!(outcome.kind, expected);
            assert!(outcome.location.is_none(), "{expected:?} has no location");
            assert_eq!(outcome.epoch, 0, "{expected:?} reports epoch 0");
            assert_eq!(
                outcome.mls_group_id,
                gid.as_slice().to_vec(),
                "{expected:?} carries the local group id"
            );
        }
    }

    /// Security Rule 4/8: `LocationMessageResultFfi`'s `Debug` must redact the
    /// raw MLS group id and the decrypted location, exposing only presence + the
    /// non-secret epoch counter. FFI debug lines routinely surface via
    /// `debugPrint` on the Flutter side, and the group id is never meant to be
    /// observable off-device. (Successor to the deleted `DecryptResultFfi` /
    /// `DecryptOutcomeFfi` redaction tests.)
    #[test]
    fn location_message_result_ffi_debug_redacts_secrets() {
        let secret_group_id = vec![0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe];
        let result = haven_core::nostr::mls::types::LocationMessageResult::Location {
            sender_pubkey: "SENDER_PK_SECRET".to_string(),
            content: sample_location_content(),
            group_id: haven_core::nostr::mls::types::GroupId::from_slice(&secret_group_id),
            epoch: 1_700_000_000,
        };
        let ffi = convert_location_result(result);
        // Sanity: the location DID parse, so `has_location` is meaningfully true.
        assert!(ffi.location.is_some());

        let debug_str = format!("{ffi:?}");
        assert!(
            !debug_str.contains("deadbeefcafebabe"),
            "Debug must not leak MLS group id hex: {debug_str}"
        );
        assert!(
            !debug_str.contains("37.77"),
            "Debug must not leak decrypted coordinates: {debug_str}"
        );
        assert!(
            !debug_str.to_lowercase().contains("sender_pk_secret"),
            "Debug must not leak the sender pubkey: {debug_str}"
        );
        // Presence flags + the non-secret epoch counter DO render.
        assert!(debug_str.contains("has_location: true"));
        assert!(
            debug_str.contains("<redacted>"),
            "group id must render redacted: {debug_str}"
        );
        assert!(
            debug_str.contains("1700000000"),
            "epoch is a non-secret counter: {debug_str}"
        );
    }

    /// W2 wire cutover: the FFI relay-list category maps to the correct Dark
    /// Matter on-wire kind — `Inbox` → 10050 (NIP-17) and the KeyPackage-
    /// discovery category (`Nip65`, which replaced the retired kind-10051
    /// `KeyPackage` variant) → 10002 (NIP-65) — and `Nip65` shares the persisted
    /// `RelayType::KeyPackage` storage slot (zero data migration). Guards against
    /// a regression that would re-publish the abolished kind-10051 list.
    #[test]
    fn relay_type_ffi_maps_nip65_to_kind_10002_and_keypackage_slot() {
        // Wire kind per category.
        assert_eq!(
            relay_list_wire_kind(RelayTypeFfi::Inbox),
            nostr::Kind::InboxRelays
        );
        assert_eq!(
            relay_list_wire_kind(RelayTypeFfi::Nip65),
            nostr::Kind::RelayList
        );
        assert_eq!(
            nostr::Kind::RelayList.as_u16(),
            10002,
            "Nip65 publishes kind 10002, not the retired 10051"
        );
        assert_eq!(nostr::Kind::InboxRelays.as_u16(), 10050);

        // Storage slot: Nip65 ↔ the persisted KeyPackage slot (W2, no migration).
        assert_eq!(
            haven_core::circle::RelayType::from(RelayTypeFfi::Nip65),
            haven_core::circle::RelayType::KeyPackage
        );
        assert_eq!(
            RelayTypeFfi::from(haven_core::circle::RelayType::KeyPackage),
            RelayTypeFfi::Nip65
        );
        assert_eq!(
            haven_core::circle::RelayType::from(RelayTypeFfi::Inbox),
            haven_core::circle::RelayType::Inbox
        );

        // The actually-built signed event carries kind 10002 for Nip65.
        let keys = nostr::Keys::generate();
        let ev = build_relay_list_event_for(
            RelayTypeFfi::Nip65,
            &keys,
            &["wss://relay.example".to_string()],
            None,
        )
        .expect("build nip65 relay-list event");
        assert_eq!(
            ev.kind,
            nostr::Kind::RelayList,
            "Nip65 relay-list event must be kind 10002"
        );
    }

    /// The seconds→milliseconds cursor conversion (M2) must scale by 1000 and
    /// saturate rather than overflow on a pathological future timestamp.
    #[test]
    fn event_secs_to_cursor_ms_converts_and_saturates() {
        assert_eq!(event_secs_to_cursor_ms(0), 0);
        assert_eq!(event_secs_to_cursor_ms(1_700_000_000), 1_700_000_000_000);
        assert_eq!(
            event_secs_to_cursor_ms(i64::MAX),
            i64::MAX,
            "saturates, no panic"
        );
        // A negative input stays negative (Dart `> 0` guards block it upstream;
        // pin the behavior so the conversion never silently wraps).
        assert_eq!(event_secs_to_cursor_ms(-5), -5000);
        assert_eq!(event_secs_to_cursor_ms(i64::MIN), i64::MIN, "saturates low");
    }
}

// ========================= M3c: Live-Sync Engine FFI =========================
//
// `LiveSyncFfi` exposes the persistent receive engine
// (`haven_core::relay::live_sync::LiveSyncCore`) to Flutter (M6). The live
// engine lives in the resettable `SESSION` global (so logout can drop it); the
// opaque handle holds only a borrow of the one MLS-state owner. Decrypted
// events are pushed to Dart over a single `StreamSink<FfiRelayEvent>`.

use haven_core::relay::live_sync::{
    CircleSpec as CoreCircleSpec, LiveSyncCore, LiveSyncEvent as CoreLiveSyncEvent,
    SyncStatusReason as CoreSyncStatusReason,
};

/// Returns the active engine, or `None` when no session is running.
///
/// `None` is the SEND-path's "engine off" signal: the Dart caller falls back to
/// the legacy eager finalize path. A poisoned lock surfaces as `Err`, never a
/// panic across the FFI boundary.
fn live_session_core() -> Result<Option<Arc<LiveSyncCore>>, String> {
    Ok(SESSION
        .read()
        .map_err(|_| "session lock poisoned".to_string())?
        .as_ref()
        .map(Arc::clone))
}

/// The active live-sync engine. `RwLock<Option<Arc<…>>>` (not `OnceLock`) so
/// logout can reset it to `None`; every access uses `.map_err(...)` and NEVER
/// `.unwrap()`, so a poisoned lock surfaces as an `Err`, never a panic across
/// the FFI boundary (mirrors `TILE_CACHE`).
static SESSION: RwLock<Option<Arc<LiveSyncCore>>> = RwLock::new(None);

/// Non-content lifecycle/status reason on the live stream. Closed enum — a raw
/// error string never crosses the FFI (Security Rule 8). Mirrors the core
/// `SyncStatusReason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSyncStatusReason {
    /// Establishing relay connections.
    Connecting,
    /// All required relays connected.
    Connected,
    /// A relay dropped; re-establishing.
    Reconnecting,
    /// A relay is disconnected.
    Disconnected,
    /// An incoming group message could not be processed (no cursor advance).
    Unprocessable,
    /// An inbox (gift-wrap) processing step failed.
    InboxError,
    /// A relay-level operation failed.
    RelayError,
    /// A session was started.
    SessionStarted,
    /// A session was stopped.
    SessionStopped,
    /// The session resumed from background.
    BackgroundResumed,
}

const fn sync_reason_to_ffi(reason: CoreSyncStatusReason) -> FfiSyncStatusReason {
    match reason {
        CoreSyncStatusReason::Connecting => FfiSyncStatusReason::Connecting,
        CoreSyncStatusReason::Connected => FfiSyncStatusReason::Connected,
        CoreSyncStatusReason::Reconnecting => FfiSyncStatusReason::Reconnecting,
        CoreSyncStatusReason::Disconnected => FfiSyncStatusReason::Disconnected,
        CoreSyncStatusReason::Unprocessable => FfiSyncStatusReason::Unprocessable,
        CoreSyncStatusReason::InboxError => FfiSyncStatusReason::InboxError,
        CoreSyncStatusReason::RelayError => FfiSyncStatusReason::RelayError,
        CoreSyncStatusReason::SessionStarted => FfiSyncStatusReason::SessionStarted,
        CoreSyncStatusReason::SessionStopped => FfiSyncStatusReason::SessionStopped,
        CoreSyncStatusReason::BackgroundResumed => FfiSyncStatusReason::BackgroundResumed,
    }
}

/// Discriminator for [`FfiRelayEvent`] (struct-of-discriminant, like
/// [`DecryptOutcomeFfi`], to avoid pulling Dart `freezed` into the bindings).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiRelayEventKind {
    /// A decrypted location.
    Location,
    /// A group membership/epoch update.
    GroupUpdate,
    /// A raw gift-wrapped invitation (`kind:1059`); the consumer unwraps it.
    Welcome,
    /// A non-content status/lifecycle signal.
    Status,
}

/// One event streamed from the live-sync engine to Flutter.
///
/// The real MLS group id NEVER appears here — only the pseudonymous
/// `nostr_group_id` (Security Rule 4). The `Debug` impl is presence-only.
pub struct FfiRelayEvent {
    /// Which kind of event this is.
    pub kind: FfiRelayEventKind,
    /// Pseudonymous `nostr_group_id` (Location / GroupUpdate).
    pub nostr_group_id: Option<Vec<u8>>,
    /// Sender's hex Nostr public key (Location).
    pub sender_pubkey: Option<String>,
    /// Decrypted location content JSON (Location).
    pub content: Option<String>,
    /// Source event `created_at` seconds (Location).
    pub event_created_at_secs: Option<i64>,
    /// Outbound commit the consumer must publish+merge (GroupUpdate; `Some`
    /// only for an auto-committed peer `SelfRemove`).
    pub evolution_event_json: Option<String>,
    /// Raw `kind:1059` gift-wrap JSON (Welcome).
    pub gift_wrap_json: Option<String>,
    /// Gift-wrap `created_at` seconds (Welcome).
    pub wrap_created_at_secs: Option<i64>,
    /// Closed status reason (Status).
    pub status_reason: Option<FfiSyncStatusReason>,
}

impl std::fmt::Debug for FfiRelayEvent {
    /// Presence-only: no coordinates, group-id bytes, content, or JSON
    /// (Security Rule 8). Relay-public timestamps + the closed status enum print.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FfiRelayEvent")
            .field("kind", &self.kind)
            .field("has_nostr_group_id", &self.nostr_group_id.is_some())
            .field("has_sender_pubkey", &self.sender_pubkey.is_some())
            .field("has_content", &self.content.is_some())
            .field("event_created_at_secs", &self.event_created_at_secs)
            .field("has_evolution_event", &self.evolution_event_json.is_some())
            .field("has_gift_wrap", &self.gift_wrap_json.is_some())
            .field("wrap_created_at_secs", &self.wrap_created_at_secs)
            .field("status_reason", &self.status_reason)
            .finish()
    }
}

fn live_event_to_ffi(event: CoreLiveSyncEvent) -> FfiRelayEvent {
    let mut out = FfiRelayEvent {
        kind: FfiRelayEventKind::Status,
        nostr_group_id: None,
        sender_pubkey: None,
        content: None,
        event_created_at_secs: None,
        evolution_event_json: None,
        gift_wrap_json: None,
        wrap_created_at_secs: None,
        status_reason: None,
    };
    match event {
        CoreLiveSyncEvent::Location {
            nostr_group_id,
            sender_pubkey,
            content,
            event_created_at_secs,
        } => {
            out.kind = FfiRelayEventKind::Location;
            out.nostr_group_id = Some(nostr_group_id);
            out.sender_pubkey = Some(sender_pubkey);
            out.content = Some(content);
            out.event_created_at_secs = Some(event_created_at_secs);
        }
        CoreLiveSyncEvent::GroupUpdate {
            nostr_group_id,
            evolution_event_json,
        } => {
            out.kind = FfiRelayEventKind::GroupUpdate;
            out.nostr_group_id = Some(nostr_group_id);
            out.evolution_event_json = evolution_event_json;
        }
        CoreLiveSyncEvent::Welcome {
            gift_wrap_json,
            wrap_created_at_secs,
        } => {
            out.kind = FfiRelayEventKind::Welcome;
            out.gift_wrap_json = Some(gift_wrap_json);
            out.wrap_created_at_secs = Some(wrap_created_at_secs);
        }
        CoreLiveSyncEvent::Status { reason } => {
            out.kind = FfiRelayEventKind::Status;
            out.status_reason = Some(sync_reason_to_ffi(reason));
        }
    }
    out
}

/// A circle to subscribe the live-sync engine to. `nostr_group_id` is the raw
/// 32-byte pseudonymous id (NEVER the MLS group id); the engine hex-encodes it
/// for the `#h` filter.
pub struct FfiGroupSpec {
    /// The circle's 32-byte `nostr_group_id`.
    pub nostr_group_id: Vec<u8>,
    /// The circle's relay set.
    pub relays: Vec<String>,
}

/// Opaque handle to the live-sync engine. Holds only a borrow of the one MLS
/// state owner; the live engine lives in the `SESSION` global.
#[frb(opaque)]
pub struct LiveSyncFfi {
    circle: Arc<CoreCircleManager>,
    own_pubkey: nostr::PublicKey,
}

impl LiveSyncFfi {
    /// Builds a handle over `circle`'s MLS state for `own_pubkey_hex`.
    ///
    /// # Errors
    ///
    /// Returns an error if `own_pubkey_hex` is not a valid Nostr public key.
    pub fn new_instance(circle: &CircleManagerFfi, own_pubkey_hex: String) -> Result<Self, String> {
        validate_pubkey_hex(&own_pubkey_hex, "own_pubkey")?;
        let pk = nostr::PublicKey::from_hex(&normalize_pubkey_hex(&own_pubkey_hex))
            .map_err(|e| e.to_string())?;
        Ok(Self {
            circle: Arc::clone(&circle.inner),
            own_pubkey: pk,
        })
    }

    /// Starts the live session over `groups` + `inbox_relays`. Idempotent — a
    /// second call while a session is live returns `Ok` without rebuilding.
    ///
    /// # Errors
    ///
    /// Returns an error if a group spec is malformed, the lock is poisoned, or a
    /// subscription fails (on which the reserved session slot is cleared).
    pub async fn start_session(
        &self,
        groups: Vec<FfiGroupSpec>,
        inbox_relays: Vec<String>,
    ) -> Result<(), String> {
        // Validate + map specs BEFORE reserving the session slot.
        let mut circles = Vec::with_capacity(groups.len());
        for g in groups {
            let id = parse_nostr_group_id(&g.nostr_group_id)?;
            circles.push(CoreCircleSpec {
                group_id_hex: hex::encode(id),
                relays: g.relays,
            });
        }

        let core = Arc::new(LiveSyncCore::new_local(
            Arc::clone(&self.circle),
            self.own_pubkey,
        ));

        // Install this handle's session as the single live engine, REPLACING
        // any existing one. The previous "if guard.is_some() { return Ok(()) }"
        // was a blind no-op: it returned success while leaving a STALE engine
        // in the process-global slot — one subscribed to a different (or empty)
        // circle set — and because `live_events()` streams from this global
        // slot, the caller then received nothing for its own circles. That
        // stale occupant arises when a prior session was not torn down before a
        // new one starts: a prior flag-on e2e scenario's engine, or (in
        // production) a rapid logout→login within a single process (the app
        // process outlives the Dart `ProviderScope`, so the static `SESSION`
        // survives). Take the previous core under the lock and drop the guard
        // BEFORE awaiting its stop — a `std::sync::RwLock` guard cannot be held
        // across `.await` (mirrors `stop_session`). A legitimate re-start is
        // always preceded by a `stop_session` that leaves the slot `None`, so
        // in a healthy single session this replace branch is never taken; it is
        // a correctness safety net for the abnormal stale-slot case, not a hot
        // path. Fork-safety: `LiveSyncCore::stop` only signals shutdown and
        // tears down the client/router; a detached path-B converge task bails
        // to a `clear_pending_commit` of its UN-merged (epoch-unadvanced)
        // commit, which the un-advanced cursor re-delivers to the next session
        // to re-stage — the documented self-heal, no fork.
        let previous = {
            SESSION
                .write()
                .map_err(|_| "session lock poisoned".to_string())?
                .take()
        };
        if let Some(previous) = previous {
            previous.stop().await;
        }
        {
            let mut guard = SESSION
                .write()
                .map_err(|_| "session lock poisoned".to_string())?;
            *guard = Some(Arc::clone(&core));
        }

        // Connect + subscribe. On failure, clear the reserved slot so a retry is
        // possible (and a leaked half-started engine does not linger) — but ONLY
        // if the slot still points at THIS core. A concurrent `start_session` may
        // have already replaced the slot with its own freshly-started core;
        // unconditionally clearing would clobber that valid session (leaving
        // `live_events()` streaming from a slot that then reads `None`). The
        // engine's per-core lifecycle lock guarantees this core's `start` ran to
        // completion (pool intact) before any concurrent `stop`, so a failure
        // here is a genuine one, not the emptied-pool race.
        if let Err(e) = core.start(&circles, &inbox_relays).await {
            // Best-effort: on a poisoned `SESSION` lock we skip the clear rather
            // than panic. The worst case is an already-stopped core (start's error
            // path ran `stop_inner`) left in the slot — degraded (`is_running()`
            // == false), never unsafe, and self-healed by the next
            // `start_session`/`stop_session`. `SESSION` write guards never span
            // panic-prone code, so poisoning is effectively unreachable.
            if let Ok(mut guard) = SESSION.write() {
                if guard.as_ref().is_some_and(|c| Arc::ptr_eq(c, &core)) {
                    *guard = None;
                }
            }
            return Err(e.to_string());
        }
        Ok(())
    }

    /// Stops + drops the live session (logout/teardown). Idempotent.
    ///
    /// # Errors
    ///
    /// Returns an error only if the session lock is poisoned.
    pub async fn stop_session(&self) -> Result<(), String> {
        let core = SESSION
            .write()
            .map_err(|_| "session lock poisoned".to_string())?
            .take();
        if let Some(core) = core {
            core.stop().await;
        }
        Ok(())
    }

    /// Re-anchors the session after a background period / reconnect.
    ///
    /// # Errors
    ///
    /// Returns an error if there is no active session, the lock is poisoned, or
    /// a re-subscription fails.
    pub async fn resume_after_background(&self) -> Result<(), String> {
        let core = SESSION
            .read()
            .map_err(|_| "session lock poisoned".to_string())?
            .as_ref()
            .map(Arc::clone);
        match core {
            Some(core) => core
                .resume_after_background()
                .await
                .map_err(|e| e.to_string()),
            None => Err("no active live-sync session".to_string()),
        }
    }

    /// Subscribes the running session to ONE additional circle (delta only), at
    /// its OWN cursor/seed, without re-anchoring any other circle's subscription
    /// (the M3-deferred incremental subscribe). Idempotent for an already-
    /// subscribed circle.
    ///
    /// # Errors
    ///
    /// Returns an error if `spec.nostr_group_id` is malformed, there is no active
    /// session, the lock is poisoned, a relay fails the WSS gate, or the
    /// subscription fails. The Dart caller falls back to a full restart on error.
    pub async fn subscribe_circle(&self, spec: FfiGroupSpec) -> Result<(), String> {
        let id = parse_nostr_group_id(&spec.nostr_group_id)?;
        let circle = CoreCircleSpec {
            group_id_hex: hex::encode(id),
            relays: spec.relays,
        };
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        core.subscribe_circle(&circle)
            .await
            .map_err(|e| e.to_string())
    }

    /// Unsubscribes the running session from ONE circle (delta only), dropping
    /// only its receive subscription. Idempotent: an unknown circle or no active
    /// session is a no-op (`Ok`).
    ///
    /// # Errors
    ///
    /// Returns an error if `nostr_group_id` is malformed, the lock is poisoned, or
    /// a multiplexed-bucket re-issue fails (the Dart caller then full-restarts).
    pub async fn unsubscribe_circle(&self, nostr_group_id: Vec<u8>) -> Result<(), String> {
        let id = parse_nostr_group_id(&nostr_group_id)?;
        let hex = hex::encode(id);
        let Some(core) = live_session_core()? else {
            return Ok(());
        };
        core.unsubscribe_circle(&hex)
            .await
            .map_err(|e| e.to_string())
    }

    /// Whether a live session is currently running.
    #[frb(sync)]
    #[must_use]
    pub fn is_running(&self) -> bool {
        SESSION
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|c| c.is_running()))
            .unwrap_or(false)
    }

    /// Streams decrypted live events to Dart for the lifetime of the session.
    ///
    /// Returns `Err` immediately if no session is active (a cold-start race, not
    /// a hung stream). The loop ends when the Dart side closes the sink
    /// (`sink.add` returns `Err`) OR the bus closes on `stop_session` (the last
    /// `Arc<LiveSyncCore>` drops → `RecvError::Closed`); a lag is skipped, never
    /// fatal (the cursor + catch-up replay anything dropped).
    ///
    /// # Errors
    ///
    /// Returns an error if there is no active session or the lock is poisoned.
    pub async fn live_events(
        &self,
        sink: crate::frb_generated::StreamSink<FfiRelayEvent>,
    ) -> Result<(), String> {
        let core = SESSION
            .read()
            .map_err(|_| "session lock poisoned".to_string())?
            .as_ref()
            .map(Arc::clone)
            .ok_or_else(|| "no active live-sync session".to_string())?;
        let mut rx = core.bus().subscribe();
        // Drop our Arc so the bus closes promptly when stop_session takes the
        // session (otherwise this clone would keep the core — and its bus —
        // alive, and the Closed branch could never fire).
        drop(core);
        loop {
            match rx.recv().await {
                Ok(event) => {
                    if sink.add(live_event_to_ffi(event)).is_err() {
                        break; // Dart closed the stream
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
        Ok(())
    }
}

/// M8-4 subscription-health maintenance tick (Dart-timer-driven, no secret).
///
/// Reads the `SESSION` global: with no live engine session it returns the inert
/// [`SubscriptionHealthActionFfi::EngineOff`] no-op, so this SHIPS INERT while
/// `liveSyncEnabled` is off (the engine is never started, so `SESSION` is
/// always empty). Once the engine is live it snapshots relay connectivity and,
/// if any relay has dropped, re-anchors every subscription at its persisted
/// cursor via `resume_after_background` — self-healing dropped subscriptions.
///
/// The `SESSION` read snapshots the `Arc` and drops the lock guard BEFORE any
/// `.await` (via [`live_session_core`]), so the returned future is `Send` and
/// the build stays clippy-clean under `-D warnings`.
///
/// Takes no secret and no circle handle. The outcome is presence-only (counts +
/// an action enum, never a relay url/id).
///
/// # Errors
///
/// Returns a redacted error string if the `SESSION` lock is poisoned or a
/// re-anchor's re-subscription fails.
pub async fn maintain_subscription_health() -> Result<SubscriptionHealthOutcomeFfi, String> {
    let Some(core) = live_session_core()? else {
        return Ok(haven_core::relay::live_sync::SubscriptionHealthOutcome::engine_off().into());
    };
    let outcome = core
        .maintain_subscription_health()
        .await
        .map_err(|e| e.to_string())?;
    Ok(outcome.into())
}

#[cfg(test)]
mod live_sync_ffi_tests {
    use super::{
        live_event_to_ffi, sync_reason_to_ffi, FfiRelayEventKind, FfiSyncStatusReason,
        SubscriptionHealthActionFfi, SubscriptionHealthOutcomeFfi,
    };
    use haven_core::relay::live_sync::{LiveSyncEvent as Ev, SyncStatusReason as R};

    #[test]
    fn maps_location_with_all_fields() {
        let f = live_event_to_ffi(Ev::Location {
            nostr_group_id: vec![1, 2, 3],
            sender_pubkey: "deadbeef".to_string(),
            content: "{\"lat\":0}".to_string(),
            event_created_at_secs: 100,
        });
        assert_eq!(f.kind, FfiRelayEventKind::Location);
        assert_eq!(f.nostr_group_id, Some(vec![1, 2, 3]));
        assert_eq!(f.sender_pubkey.as_deref(), Some("deadbeef"));
        assert_eq!(f.content.as_deref(), Some("{\"lat\":0}"));
        assert_eq!(f.event_created_at_secs, Some(100));
        assert!(f.status_reason.is_none() && f.gift_wrap_json.is_none());
    }

    #[test]
    fn maps_group_update_welcome_and_status() {
        let g = live_event_to_ffi(Ev::GroupUpdate {
            nostr_group_id: vec![9],
            evolution_event_json: Some("commit".to_string()),
        });
        assert_eq!(g.kind, FfiRelayEventKind::GroupUpdate);
        assert_eq!(g.evolution_event_json.as_deref(), Some("commit"));

        let w = live_event_to_ffi(Ev::Welcome {
            gift_wrap_json: "wrap".to_string(),
            wrap_created_at_secs: 7,
        });
        assert_eq!(w.kind, FfiRelayEventKind::Welcome);
        assert_eq!(w.gift_wrap_json.as_deref(), Some("wrap"));
        assert_eq!(w.wrap_created_at_secs, Some(7));

        let s = live_event_to_ffi(Ev::Status {
            reason: R::BackgroundResumed,
        });
        assert_eq!(s.kind, FfiRelayEventKind::Status);
        assert_eq!(
            s.status_reason,
            Some(FfiSyncStatusReason::BackgroundResumed)
        );
    }

    #[test]
    fn ffi_relay_event_debug_is_presence_only() {
        let f = live_event_to_ffi(Ev::Location {
            nostr_group_id: vec![0xAB, 0xCD],
            sender_pubkey: "SENDER_PK".to_string(),
            content: "SECRET_COORDS".to_string(),
            event_created_at_secs: 42,
        });
        let dbg = format!("{f:?}");
        assert!(!dbg.contains("SENDER_PK"), "leaked sender: {dbg}");
        assert!(!dbg.contains("SECRET_COORDS"), "leaked content: {dbg}");
        assert!(
            !dbg.contains("abcd") && !dbg.contains("ABCD"),
            "leaked group id: {dbg}"
        );
        assert!(dbg.contains("42"), "relay-public ts should show");
        assert!(dbg.contains("Location"));

        // GroupUpdate: the outbound commit JSON MUST be redacted, but its
        // presence renders as a boolean flag.
        let g = live_event_to_ffi(Ev::GroupUpdate {
            nostr_group_id: vec![0xAB, 0xCD],
            evolution_event_json: Some("SECRET_EVOLUTION".to_string()),
        });
        let dbg = format!("{g:?}");
        assert!(
            !dbg.contains("SECRET_EVOLUTION"),
            "leaked evolution json: {dbg}"
        );
        assert!(
            dbg.contains("has_evolution_event: true"),
            "presence flag must render: {dbg}"
        );

        // Welcome: the raw gift-wrap JSON MUST be redacted, presence flagged.
        let w = live_event_to_ffi(Ev::Welcome {
            gift_wrap_json: "SECRET_WRAP".to_string(),
            wrap_created_at_secs: 7,
        });
        let dbg = format!("{w:?}");
        assert!(!dbg.contains("SECRET_WRAP"), "leaked gift-wrap json: {dbg}");
        assert!(
            dbg.contains("has_gift_wrap: true"),
            "presence flag must render: {dbg}"
        );
    }

    #[test]
    fn subscription_health_outcome_maps_and_is_presence_only() {
        use haven_core::relay::live_sync::{HealthAction, SubscriptionHealthOutcome};
        // The engine-off core outcome maps to the inert FFI no-op.
        let off: SubscriptionHealthOutcomeFfi = SubscriptionHealthOutcome::engine_off().into();
        assert_eq!(off.action, SubscriptionHealthActionFfi::EngineOff);
        assert_eq!(off.relays_total, 0);
        assert_eq!(off.relays_still_connecting, 0);
        assert_eq!(off.relays_disconnected, 0);

        // A resubscribed outcome passes its counts through unchanged, including
        // the still-connecting bucket.
        let resub: SubscriptionHealthOutcomeFfi = SubscriptionHealthOutcome {
            action: HealthAction::Resubscribed,
            relays_total: 3,
            relays_still_connecting: 1,
            relays_disconnected: 2,
        }
        .into();
        assert_eq!(resub.action, SubscriptionHealthActionFfi::Resubscribed);
        assert_eq!(resub.relays_total, 3);
        assert_eq!(resub.relays_still_connecting, 1);
        assert_eq!(resub.relays_disconnected, 2);

        // Debug is presence-only: an action name + integer counters, nothing
        // that could carry a relay url / group id.
        let dbg = format!("{resub:?}");
        assert!(dbg.contains("Resubscribed"));
        assert!(dbg.contains('3') && dbg.contains('2'));
    }

    #[test]
    fn sync_reason_maps_every_variant() {
        // Pin the full mapping so a new core reason can't silently drop.
        for (core, ffi) in [
            (R::Connecting, FfiSyncStatusReason::Connecting),
            (R::Connected, FfiSyncStatusReason::Connected),
            (R::Reconnecting, FfiSyncStatusReason::Reconnecting),
            (R::Disconnected, FfiSyncStatusReason::Disconnected),
            (R::Unprocessable, FfiSyncStatusReason::Unprocessable),
            (R::InboxError, FfiSyncStatusReason::InboxError),
            (R::RelayError, FfiSyncStatusReason::RelayError),
            (R::SessionStarted, FfiSyncStatusReason::SessionStarted),
            (R::SessionStopped, FfiSyncStatusReason::SessionStopped),
            (R::BackgroundResumed, FfiSyncStatusReason::BackgroundResumed),
        ] {
            assert_eq!(sync_reason_to_ffi(core), ffi);
        }
    }
}

// REMOVED (Dark Matter migration): `mod send_path_ffi_tests`. Its entire subject
// — the Dart-side settle-window convergence + staged-commit send-path FFI
// (`converge_result_to_ffi`, `ConvergeIntentFfi`/`ConvergeIntentKind`,
// `ConvergeResultKind`, `StagedCommitFfi`/`StagedAddFfi`, and the core
// `CommitConvergence`/`CommitIntent` they mapped) — was DELETED. Convergence is
// now engine-owned (branch selection happens inside the MDK engine), and the
// send path is publish-before-apply (`CommitToPublishFfi` +
// `confirm_published`/`publish_failed`, Rule 13). There is no FFI-helper-level
// conversion surface left to unit-test here; the publish-before-apply commit
// lifecycle needs a live manager and is exercised by the live-sync e2e lanes.

// ============================================================================
// KeyPackage maintenance — REAL-FFI end-to-end over MockRelay (Dark Matter).
//
// Unlike `haven-core/tests/maintenance_per_relay_e2e_test.rs` (a hand-written
// MIRROR that re-implements the probe → decide → publish logic itself), these
// tests drive the ACTUAL FFI orchestration `RelayManagerFfi::maintain_key_package`
// — which cannot be reached from `haven-core` because it lives here in
// `rust_builder`. They construct a REAL `CircleManagerFfi` (real Dark Matter
// `session.sqlite` + `circles.db` on the in-memory keyring) and a REAL
// `RelayManagerFfi`, point them at an in-process `MockRelay`, and assert the
// outcome against the relay's actual stored state.
//
// Dark Matter migration note: the pre-migration setup helpers
// `sign_key_package_event` + `record_published_key_packages` + the manual
// `publish_event` twins (and the M8-2 dead-material "live gate") were DELETED —
// `maintain_key_package` is now the ONE publish path (decide → reuse-or-mint →
// publish OWN-relays-only → record), and presence is pure relay presence of the
// tracked stable `d`. So each test now uses `maintain_key_package` itself as the
// first-publish setup, then drives it again to assert the surviving invariants:
//   * TC-1: a fresh mint reads AlreadyHealthy on the very next tick (idempotent
//     when live + tracked; never a force-rotate) — re-expressed.
//   * TC-3: per-relay presence isolation — a relay serving the tracked slot is
//     left UNTOUCHED while a newly-added empty relay is republished-to — the
//     surviving half of the partial-drop fix, re-expressed over the presence gate.
// TC-2 (aged-out-dead-material → republish + kind-5 GC of the 443 twin) was
// DELETED with its subject: the dead-material gate is gone and there is no more
// 443 twin on the publish path (the legacy 443/10051 hygiene moved to the
// one-time `retract_legacy_key_material` retraction cutover, not maintenance).
//
// Security: presence-only — no secret bytes, `d` slots, hash_refs, or group ids
// are printed or asserted on; only event kinds, counts, action enums, and public
// event ids (which are on-wire public) appear.
// ============================================================================
#[cfg(test)]
#[cfg(debug_assertions)] // the ws:// loopback + in-memory-keyring seams are debug-only
mod maintenance_real_ffi_tests {
    use super::{
        allow_ws_loopback_for_test, use_in_memory_keyring_for_test, CircleManagerFfi,
        KpMaintenanceActionFfi, RelayManagerFfi, RelayTypeFfi,
    };
    use nostr::{Keys, Kind};
    use nostr_relay_builder::MockRelay;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    /// A fresh, unique data dir for a real `CircleManagerFfi`. Uses pid + a
    /// monotonic counter so concurrent tests never collide; removed on drop.
    struct DataDir(std::path::PathBuf);

    impl DataDir {
        fn new(tag: &str) -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let pid = std::process::id();
            let path = std::env::temp_dir().join(format!("haven_maint_ffi_{tag}_{pid}_{n}"));
            std::fs::create_dir_all(&path).expect("create data dir");
            Self(path)
        }

        fn as_str(&self) -> String {
            self.0.to_string_lossy().to_string()
        }
    }

    impl Drop for DataDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Installs the process-wide debug-only seams every test in this module
    /// needs: the in-memory keyring backend (so `CircleManagerFfi::new` works
    /// headless) and the `ws://` loopback opt-in (so the real relay manager +
    /// the storage `add_user_relay` path accept MockRelay's `ws://127.0.0.1`
    /// URL). Both are install-once and idempotent.
    fn install_test_seams() {
        // Idempotent; a second install returns Err which we ignore.
        let _ = use_in_memory_keyring_for_test();
        let _ = allow_ws_loopback_for_test();
    }

    /// A generic 32-byte identity secret. Deterministic per test call is fine —
    /// the keys never touch a real network beyond the local MockRelay.
    fn secret_bytes(keys: &Keys) -> Vec<u8> {
        keys.secret_key().to_secret_bytes().to_vec()
    }

    /// The NIP-33 `d` of a kind-30443 event (public tag; used only to assert the
    /// republished canonical reuses the stable slot). Never a secret.
    fn kp_d_tag(ev: &nostr::Event) -> Option<String> {
        ev.tags.iter().find_map(|t| {
            let s = t.as_slice();
            (s.len() >= 2 && s[0] == "d").then(|| s[1].clone())
        })
    }

    /// Fetches every event of `kind` authored by `author` from a single relay,
    /// via a bare publisher client (mirrors the mirror test's `fetch_by_kind`).
    async fn fetch_by_kind(author: nostr::PublicKey, kind: Kind, relay: &str) -> Vec<nostr::Event> {
        let client = nostr_sdk::Client::builder().build();
        client.add_relay(relay).await.expect("add relay");
        client.connect().await;
        let filter = nostr::Filter::new().kind(kind).author(author).limit(64);
        let events = client
            .fetch_events(filter, Duration::from_secs(5))
            .await
            .expect("fetch events");
        client.shutdown().await;
        events.into_iter().collect()
    }

    // ------------------------------------------------------------------------
    // TC-1 / TC-7: Live + tracked → AlreadyHealthy (idempotent, no force-rotate).
    //
    // Drives: CircleManagerFfi::new, ::add_user_relay, and the REAL
    //         RelayManagerFfi::maintain_key_package (twice).
    //
    // Re-expressed (Dark Matter): the deleted manual setup
    // (`sign_key_package_event` + `publish_event` twins +
    // `record_published_key_packages`) is replaced by the FIRST
    // `maintain_key_package` tick, which IS the publish path — a responding own
    // relay serving nothing + no tracked slot mints a fresh KeyPackage and
    // publishes it (RepublishedFreshD). The SECOND tick must then read the
    // now-live, tracked KeyPackage as AlreadyHealthy and NOT force-rotate it. A
    // regression (misreading the primary KP as dead) would republish every tick.
    // ------------------------------------------------------------------------
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn tc1_live_tracked_kp_is_already_healthy_via_real_ffi() {
        // Serialize with the M10 wipe tests + sibling tc* tests: they share the
        // fixed global keyring key-ids that `CircleManagerFfi::new` provisions.
        let _keyring_guard = super::SHARED_KEYRING_TEST_LOCK.lock().await;
        install_test_seams();
        let relay = MockRelay::run().await.expect("start MockRelay");
        let url = relay.url().await.to_string();

        let keys = Keys::generate();
        let author = keys.public_key();
        let secret = secret_bytes(&keys);

        // REAL manager (real Dark Matter session + circles.db) + REAL relay mgr.
        let dir = DataDir::new("healthy");
        let circle =
            CircleManagerFfi::new(dir.as_str(), secret.clone()).expect("CircleManagerFfi::new");
        let relay_mgr = RelayManagerFfi::new_instance()
            .await
            .expect("RelayManagerFfi::new_instance");

        // The MockRelay is the user's ONLY own NIP-65 (KeyPackage-discovery)
        // relay. A fresh manager seeds no defaults, so this is the entire
        // own-relay probe/publish set — no real network is ever touched.
        circle
            .add_user_relay(url.clone(), RelayTypeFfi::Nip65)
            .await
            .expect("register own NIP-65 relay");

        // FIRST tick = the real first-publish path (replaces the deleted manual
        // sign/publish/record): mint a fresh KeyPackage into a new slot and
        // publish it to the own relay.
        let first = circle_maintain(&relay_mgr, &circle, secret.clone()).await;
        assert_eq!(
            first.action,
            KpMaintenanceActionFfi::RepublishedFreshD,
            "the first tick on an empty own relay must mint + publish a fresh slot"
        );
        // Let the relay persist before the second probe reads it back.
        tokio::time::sleep(Duration::from_millis(250)).await;

        // Capture the published canonical id so we can prove it stays UNTOUCHED.
        let after_first = fetch_by_kind(author, Kind::Custom(30443), &url).await;
        assert_eq!(
            after_first.len(),
            1,
            "exactly one canonical 30443 must be on the relay after first publish"
        );
        let original_id = after_first
            .first()
            .expect("one canonical present")
            .id
            .to_hex();

        // SECOND tick: DRIVE THE REAL FFI again. The live, tracked KP must read
        // healthy — no rotation.
        let outcome = circle_maintain(&relay_mgr, &circle, secret).await;
        assert_eq!(
            outcome.action,
            KpMaintenanceActionFfi::AlreadyHealthy,
            "a live, tracked KeyPackage must be AlreadyHealthy, not rotated"
        );
        assert_eq!(
            outcome.relays_healed, 0,
            "nothing may be healed when healthy"
        );
        assert_eq!(
            outcome.responders_probed, 1,
            "the one own relay must have responded"
        );
        assert!(
            outcome.canonical_on_relays >= 1,
            "the probe must have observed the published canonical on the relay"
        );

        // And the relay still serves EXACTLY the original canonical id — the FFI
        // did not publish a rival 30443 over the healthy one.
        let on_relay = fetch_by_kind(author, Kind::Custom(30443), &url).await;
        assert!(
            on_relay.iter().any(|e| e.id.to_hex() == original_id),
            "the original tracked canonical must still be on the relay untouched"
        );
        // No deletion (kind 5) is ever published on the healthy path.
        let deletions = fetch_by_kind(author, Kind::EventDeletion, &url).await;
        assert!(
            deletions.is_empty(),
            "AlreadyHealthy must never publish a NIP-09 deletion"
        );

        relay.shutdown();
    }

    // REMOVED (Dark Matter migration): `tc2_stale_relay_republishes_and_gcs_legacy_twin_via_real_ffi`.
    // Its subject — the M8-2 aged-out "dead-material" live gate forcing a
    // Republish plus a self-authored kind-5 NIP-09 GC of the superseded legacy
    // 443 twin — no longer exists in production: presence is now pure relay
    // presence of the tracked stable `d` (there is no live-material verdict), and
    // `maintain_key_package` publishes ONLY the addressable kind-30443 (no 443
    // twin, so nothing to GC on the publish path). The legacy 443/10051 hygiene
    // moved to the one-time `retract_legacy_key_material` retraction cutover, not
    // per-tick maintenance. Its dead-material state was fabricated via the deleted
    // `record_published_key_packages` seam, which no longer exists. The surviving
    // "republish into the SAME stable `d`, leaving healthy relays untouched"
    // invariant is retained by the re-expressed per-relay isolation test below.

    // ------------------------------------------------------------------------
    // TC-3: Per-relay presence isolation — one relay already serving the tracked
    // slot + one freshly-added empty relay.
    //
    // Drives the REAL maintain_key_package across TWO own relays. The relay that
    // already serves the tracked stable `d` (published on the first tick) must be
    // left UNTOUCHED (RepublishedStableD targets only the drop), while only the
    // newly-added empty relay is republished-to. This is the surviving half of
    // the headline partial-drop fix, exercised through the real FFI over the Dark
    // Matter presence gate. Re-expressed: a relay added AFTER the first publish
    // stands in for a per-relay drop, since the deleted `record_published_key_packages`
    // seam can no longer fabricate a dead-material state.
    // ------------------------------------------------------------------------
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn tc3_per_relay_isolation_heals_only_empty_relay_via_real_ffi() {
        // Serialize with the M10 wipe tests + sibling tc* tests: they share the
        // fixed global keyring key-ids that `CircleManagerFfi::new` provisions.
        let _keyring_guard = super::SHARED_KEYRING_TEST_LOCK.lock().await;
        install_test_seams();
        let relay_live = MockRelay::run().await.expect("start live MockRelay");
        let relay_empty = MockRelay::run().await.expect("start empty MockRelay");
        let url_live = relay_live.url().await.to_string();
        let url_empty = relay_empty.url().await.to_string();

        let keys = Keys::generate();
        let author = keys.public_key();
        let secret = secret_bytes(&keys);

        let dir = DataDir::new("isolation");
        let circle =
            CircleManagerFfi::new(dir.as_str(), secret.clone()).expect("CircleManagerFfi::new");
        let relay_mgr = RelayManagerFfi::new_instance()
            .await
            .expect("RelayManagerFfi::new_instance");

        // Only the LIVE relay is configured for the first publish, so the tracked
        // canonical lands ONLY there (the empty relay is not yet in the own set).
        circle
            .add_user_relay(url_live.clone(), RelayTypeFfi::Nip65)
            .await
            .expect("register live own relay");
        let first = circle_maintain(&relay_mgr, &circle, secret.clone()).await;
        assert_eq!(
            first.action,
            KpMaintenanceActionFfi::RepublishedFreshD,
            "the first tick must mint + publish the tracked slot to the live relay"
        );
        tokio::time::sleep(Duration::from_millis(250)).await;

        // Capture the live relay's canonical (id + stable `d`): it must stay
        // untouched, and its `d` is the slot the healed relay must receive.
        let on_live_before = fetch_by_kind(author, Kind::Custom(30443), &url_live).await;
        assert_eq!(
            on_live_before.len(),
            1,
            "the live relay must serve exactly the one first-published canonical"
        );
        let live_canonical = on_live_before.first().expect("one canonical present");
        let live_id = live_canonical.id.to_hex();
        let stable_d = kp_d_tag(live_canonical).expect("published canonical carries a `d`");

        // Now add a SECOND own relay that serves NOTHING — a per-relay drop under
        // the presence gate (tracked slot present on `live`, absent on `empty`).
        circle
            .add_user_relay(url_empty.clone(), RelayTypeFfi::Nip65)
            .await
            .expect("register empty own relay");

        // DRIVE THE REAL FFI across both relays.
        let outcome = circle_maintain(&relay_mgr, &circle, secret).await;
        assert_eq!(
            outcome.responders_probed, 2,
            "both own relays must have responded"
        );
        assert_eq!(
            outcome.action,
            KpMaintenanceActionFfi::RepublishedStableD,
            "the per-relay drop must trigger a stable-slot republish"
        );
        assert_eq!(
            outcome.relays_healed, 1,
            "exactly the ONE empty relay must be healed (per-relay isolation)"
        );

        tokio::time::sleep(Duration::from_millis(400)).await;

        // The LIVE relay must STILL serve its original canonical, and NOT a rival
        // republished id (it was already healthy → skipped).
        let on_live = fetch_by_kind(author, Kind::Custom(30443), &url_live).await;
        assert!(
            on_live.iter().any(|e| e.id.to_hex() == live_id),
            "the healthy relay must retain its original canonical"
        );
        assert!(
            !on_live.iter().any(|e| {
                e.id.to_hex() != live_id && kp_d_tag(e).as_deref() == Some(stable_d.as_str())
            }),
            "no rival same-`d` canonical may be published to the already-healthy relay"
        );

        // The EMPTY relay must now serve a canonical in the SAME stable `d`.
        let on_empty = fetch_by_kind(author, Kind::Custom(30443), &url_empty).await;
        assert!(
            on_empty
                .iter()
                .any(|e| kp_d_tag(e).as_deref() == Some(stable_d.as_str())),
            "the healed relay must receive a republished same-`d` canonical"
        );

        relay_live.shutdown();
        relay_empty.shutdown();
    }

    /// Thin wrapper so each test reads as one call to the REAL FFI under test.
    async fn circle_maintain(
        relay_mgr: &RelayManagerFfi,
        circle: &CircleManagerFfi,
        secret: Vec<u8>,
    ) -> super::KpMaintenanceOutcomeFfi {
        relay_mgr
            .maintain_key_package(circle, secret)
            .await
            .expect("maintain_key_package must not error")
    }
}
