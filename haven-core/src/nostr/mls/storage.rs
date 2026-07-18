//! Storage configuration for the Marmot "Dark Matter" MLS stack.
//!
//! This module resolves the on-disk location and the `SQLCipher` key for the MLS
//! `AccountDeviceSession`'s database (`session.sqlite`) and constructs the
//! `storage-sqlite` backend the session runs on. The database persists MLS
//! group state, `OpenMLS` value rows, and message projections.
//!
//! # Key custody (security F5)
//!
//! Unlike the old `MdkSqliteStorage`, which owned the keyring integration
//! internally, the Dark Matter `storage-sqlite` crate takes a passphrase and
//! does NOT touch the platform keyring. Haven therefore provisions the
//! passphrase here: on first use it mints 32 bytes of `OsRng` entropy, stores
//! the RAW bytes in the platform keyring, and derives a lowercase-hex passphrase
//! from them. `SqliteAccountStorage` feeds that passphrase through `SQLCipher`'s
//! PBKDF2 (`PRAGMA key = '<str>'`, `cipher_compatibility = 4`) — so the
//! passphrase is a defense-in-depth *stretch* over already-256-bit-strong
//! material. The passphrase is `Zeroizing` end to end (keyring buffer, hex
//! string, and the `SqlCipherKey` copy) and is NEVER logged.
//!
//! This is deliberately incompatible with `circles.db` / `tiles.db`, which use
//! the raw-key form (`PRAGMA key = "x'<64-hex>'"`, KDF bypassed). The MLS DB is
//! wiped-and-recreated on the Dark Matter cutover, so there is no in-place
//! re-key to reconcile.
//!
//! # Legacy database (kept for the cutover wipe — security F6)
//!
//! The pre-Dark-Matter `haven_mdk.db` path and its `mdk.db.key.default` keyring
//! entry are retained as `legacy_*` constants so the DM-5 cutover can delete the
//! old database files AND destroy the old keyring key. Unlinking the file is not
//! a secure erase (the old DB was not written with `secure_delete`, and flash
//! wear-levelling leaves residual ciphertext), so key destruction is the
//! practical secure-erase for the abandoned `SQLCipher` database.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use rand::rngs::OsRng;
use rand::RngCore;
use storage_sqlite::{SqlCipherKey, SqliteAccountStorage, SqliteStorageOptions};
use zeroize::Zeroizing;

use crate::nostr::error::{NostrError, Result};

/// Process-global registry of the canonical `session.sqlite` paths that a live
/// [`AccountDeviceSession`] currently holds open (Rule 14 runtime enforcement).
///
/// [`AccountDeviceSession`]: cgka_session::AccountDeviceSession
static LIVE_SESSIONS: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();

fn live_sessions() -> &'static Mutex<HashSet<PathBuf>> {
    LIVE_SESSIONS.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Normalizes a `session.sqlite` path to a stable registry key.
///
/// The DB file itself may not exist yet on a first open, so the *parent
/// directory* (which the caller creates before opening) is canonicalized and
/// the file name re-attached. This makes two spellings of the same file
/// (relative vs absolute, `.`/`..` segments, a symlinked parent) collide on one
/// key. If canonicalization fails (parent gone), the raw path is used verbatim —
/// a fail-safe that can only ever be *stricter* (it never merges two distinct
/// files).
fn canonical_session_key(db_path: &Path) -> PathBuf {
    match (db_path.parent(), db_path.file_name()) {
        (Some(parent), Some(name)) => parent
            .canonicalize()
            .map_or_else(|_| db_path.to_path_buf(), |canon| canon.join(name)),
        _ => db_path.to_path_buf(),
    }
}

/// RAII registration of a live MLS session's database path (Security Rule 14).
///
/// Rule 14 mandates **exactly one** live `AccountDeviceSession` per
/// `session.sqlite` across *every* Dart isolate and background worker in the
/// process. A second, divergent hydrated session would run its own in-memory
/// epoch state and risk exporter-key / epoch reuse — a confidentiality loss, not
/// merely DB corruption. The concrete threat is an Android `WorkManager`
/// background isolate constructing its own `CircleManager` on the same
/// `data_dir`: Rust statics are shared across all Dart isolates in one loaded
/// `.so`, so this process-global registry catches exactly that case.
///
/// [`Self::acquire`] fails closed if the path is already registered; the guard
/// releases the path on `Drop`, so a legitimately-closed session can be reopened
/// with no false lockout.
///
/// # Cross-process scope (documented decision)
///
/// This guard is **per-process only**. A separate OS advisory lock (`flock`)
/// would add cross-process defense-in-depth, but it is deliberately NOT used:
/// (a) the identified threat — background isolates — is same-process, which this
/// registry fully covers; (b) `flock` needs a third-party crate or `unsafe`
/// (denied crate-wide) and interacts with `SQLCipher`/WAL's own OS locks on the
/// same file across the five target platforms (Linux/macOS/iOS/Android/Windows);
/// and (c) `SQLCipher` already takes its own OS-level DB lock, so a genuinely
/// separate process opening the file is already contended at the storage layer.
/// If a future requirement needs cross-process exclusion, add a `flock` on a
/// dedicated sidecar lock file here.
#[derive(Debug)]
pub struct LiveSessionGuard {
    key: PathBuf,
}

impl LiveSessionGuard {
    /// Registers `db_path` as a live session, failing closed if another live
    /// session already holds the same canonical path (Rule 14).
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if a live session already holds this
    /// database file.
    pub fn acquire(db_path: &Path) -> Result<Self> {
        let key = canonical_session_key(db_path);
        // A poisoned lock is benign here — the set only gains/loses PathBufs, so
        // recover the guarded set rather than propagate the panic. The guard is a
        // temporary scoped to this statement so it drops before `Self` is built.
        let inserted = live_sessions()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(key.clone());
        if inserted {
            Ok(Self { key })
        } else {
            Err(NostrError::StorageError(
                "an MLS session is already open on this database \
                 (Rule 14: exactly one live session per DB file)"
                    .to_string(),
            ))
        }
    }
}

impl Drop for LiveSessionGuard {
    fn drop(&mut self) {
        live_sessions()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&self.key);
    }
}

/// Keyring service identifier (reverse-DNS). Shared with `circles.db` /
/// `tiles.db` in the FFI layer so all Haven keyring items live under one
/// service.
const SERVICE_ID: &str = "com.oblivioustech.haven";

/// Keyring key identifier for the Dark Matter MLS session passphrase.
const MLS_DB_KEY_ID: &str = "mls.session.key.default";

/// File name of the Dark Matter MLS database.
const MLS_DB_FILENAME: &str = "session.sqlite";

/// Pre-Dark-Matter MLS database file name. Retained only so the cutover wipe
/// can find and delete it (plus its WAL/SHM/journal sidecars).
const LEGACY_MLS_DB_FILENAME: &str = "haven_mdk.db";

/// Pre-Dark-Matter MLS DB keyring key identifier. Retained only so the cutover
/// can destroy it (security F6).
const LEGACY_MLS_DB_KEY_ID: &str = "mdk.db.key.default";

/// Configuration for the MLS session storage.
///
/// Holds the data directory and derives the `session.sqlite` path plus the
/// `SQLCipher` key from it. The actual database is opened either directly via
/// [`StorageConfig::open_encrypted_storage`] or — in production, from DM-2
/// onward — inside `AccountDeviceSession::open`, which opens the SAME file from
/// the [`database_path`](StorageConfig::database_path),
/// [`sqlcipher_key`](StorageConfig::sqlcipher_key), and
/// [`storage_options`](StorageConfig::storage_options) this config supplies.
#[derive(Debug, Clone)]
pub struct StorageConfig {
    /// Directory where the MLS database (and its sidecars) live. Created on
    /// demand.
    pub data_dir: PathBuf,
}

impl StorageConfig {
    /// Creates a new storage configuration rooted at `data_dir`.
    ///
    /// The directory is created lazily when the database is opened.
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        Self {
            data_dir: data_dir.as_ref().to_path_buf(),
        }
    }

    /// Path to the Dark Matter MLS database file (`session.sqlite`).
    #[must_use]
    pub fn database_path(&self) -> PathBuf {
        self.data_dir.join(MLS_DB_FILENAME)
    }

    /// Path to the pre-Dark-Matter MLS database file (`haven_mdk.db`).
    ///
    /// Present only so the cutover wipe can locate the abandoned database and
    /// its sidecars; nothing reads or writes it at runtime.
    #[must_use]
    pub fn legacy_database_path(&self) -> PathBuf {
        self.data_dir.join(LEGACY_MLS_DB_FILENAME)
    }

    /// The `storage-sqlite` options the session opens with.
    ///
    /// The defaults are exactly the hardened posture Haven wants: WAL journalling,
    /// `secure_delete`, `cipher_memory_security`, and `cipher_compatibility = 4`.
    #[must_use]
    pub fn storage_options() -> SqliteStorageOptions {
        SqliteStorageOptions::default()
    }

    /// Resolves the `SQLCipher` key for `session.sqlite`, provisioning it on first
    /// use.
    ///
    /// On first call this mints a fresh 32-byte `OsRng` passphrase, stores the
    /// raw bytes in the platform keyring under
    /// (`com.oblivioustech.haven`, `mls.session.key.default`), and on iOS
    /// migrates the entry to `AfterFirstUnlockThisDeviceOnly` so a locked-device
    /// background wake can open the database. Subsequent calls read it back.
    ///
    /// The returned [`SqlCipherKey`] wraps a `Zeroizing<String>` and is
    /// Debug-redacted; the passphrase is never logged.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the keyring is unavailable or the
    /// key cannot be constructed.
    pub fn sqlcipher_key(&self) -> Result<SqlCipherKey> {
        let passphrase = get_or_create_passphrase(SERVICE_ID, MLS_DB_KEY_ID)?;

        // Migrate the freshly-created key's iOS access policy so a locked-device
        // background wake can read it. No-op on every other target; non-fatal
        // (the migration restores the key on any failure, so a failure here
        // leaves storage fully functional). The warning carries no key material.
        if let Err(e) =
            crate::keyring_policy::ensure_db_key_after_first_unlock(SERVICE_ID, MLS_DB_KEY_ID)
        {
            log::warn!("MLS session DB key access-policy migration deferred: {e}");
        }

        // `as_str()` copies into a fresh String that `SqlCipherKey::new` moves
        // into its own `Zeroizing<String>`; `passphrase` is zeroized on drop.
        SqlCipherKey::new(passphrase.as_str())
            .map_err(|e| NostrError::StorageError(format!("Failed to build SQLCipher key: {e}")))
    }

    /// Opens (or creates) the encrypted `session.sqlite` backend.
    ///
    /// Creates the data directory if missing, resolves the `SQLCipher` key via
    /// [`sqlcipher_key`](StorageConfig::sqlcipher_key), and opens the
    /// `storage-sqlite` backend with the hardened options.
    ///
    /// # Single-session invariant (security F4 / Rule 14)
    ///
    /// At most ONE live handle on `session.sqlite` may exist across all isolates
    /// and processes: two opens hydrate two divergent in-memory epoch states,
    /// which risks exporter-key/epoch reuse and forward-secrecy erosion. In
    /// production (DM-2 onward) the session opens this file itself; do NOT call
    /// this while a session is live on the same directory.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the directory cannot be created,
    /// the keyring is unavailable, or the database cannot be opened/decrypted.
    pub fn open_encrypted_storage(&self) -> Result<SqliteAccountStorage> {
        std::fs::create_dir_all(&self.data_dir).map_err(|e| {
            NostrError::StorageError(format!(
                "Failed to create data directory {}: {e}",
                self.data_dir.display()
            ))
        })?;

        let key = self.sqlcipher_key()?;
        SqliteAccountStorage::open_encrypted_with_options(
            self.database_path(),
            &key,
            Self::storage_options(),
        )
        .map_err(|e| NostrError::StorageError(format!("Failed to open MLS storage: {e}")))
    }

    /// Creates an ephemeral, unencrypted in-memory MLS storage backend for
    /// tests.
    ///
    /// Replaces the old `MdkSqliteStorage::new_unencrypted`. The Dark Matter
    /// `SqliteAccountStorage::in_memory()` constructor is public and un-gated
    /// upstream; this feature-gated wrapper keeps the "test-only" contract on
    /// Haven's side (no keyring, no on-disk plaintext).
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::StorageError`] if the in-memory database cannot be
    /// initialized.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn in_memory_storage() -> Result<SqliteAccountStorage> {
        SqliteAccountStorage::in_memory().map_err(|e| {
            NostrError::StorageError(format!("Failed to open in-memory MLS storage: {e}"))
        })
    }
}

/// Reads the MLS DB passphrase from the keyring, minting it on first use.
///
/// The keyring holds the RAW 32-byte secret; the returned passphrase is its
/// lowercase-hex encoding. Both the raw bytes and the hex string are
/// `Zeroizing`.
fn get_or_create_passphrase(service: &str, key_id: &str) -> Result<Zeroizing<String>> {
    let entry = keyring_core::Entry::new(service, key_id)
        .map_err(|_| NostrError::StorageError("keyring unavailable".to_string()))?;

    match entry.get_secret() {
        Ok(secret_bytes) => {
            let bytes = Zeroizing::new(secret_bytes);
            Ok(Zeroizing::new(hex::encode(bytes.as_slice())))
        }
        Err(keyring_core::Error::NoEntry) => {
            let mut key_bytes = Zeroizing::new([0u8; 32]);
            OsRng.fill_bytes(key_bytes.as_mut());
            entry.set_secret(key_bytes.as_ref()).map_err(|_| {
                NostrError::StorageError("failed to persist MLS DB key".to_string())
            })?;
            Ok(Zeroizing::new(hex::encode(key_bytes.as_ref())))
        }
        Err(_) => Err(NostrError::StorageError(
            "failed to read MLS DB key from keyring".to_string(),
        )),
    }
}

/// Destroys the pre-Dark-Matter MLS DB keyring entry (`mdk.db.key.default`).
///
/// Called on the Dark Matter cutover (DM-5). Because unlinking `haven_mdk.db` is
/// not a secure erase, destroying its key is the practical secure-erase for the
/// abandoned `SQLCipher` database (security F6). Idempotent: a missing entry — or
/// no installed store — is treated as success, since nothing is then left at
/// rest. Any other keyring failure is propagated so the caller can retry.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if a genuine keyring failure (e.g. a
/// locked / unavailable Secret Service) leaves the legacy key at rest.
pub fn destroy_legacy_mls_key_material() -> Result<()> {
    let entry = match keyring_core::Entry::new(SERVICE_ID, LEGACY_MLS_DB_KEY_ID) {
        Ok(entry) => entry,
        // No store installed / no matching entry ⇒ nothing left at rest.
        Err(keyring_core::Error::NoDefaultStore | keyring_core::Error::NoEntry) => return Ok(()),
        Err(_) => {
            return Err(NostrError::StorageError(
                "failed to destroy legacy MLS DB key".to_string(),
            ))
        }
    };
    match entry.delete_credential() {
        Ok(()) | Err(keyring_core::Error::NoEntry) => Ok(()),
        Err(_) => Err(NostrError::StorageError(
            "failed to destroy legacy MLS DB key".to_string(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Once;

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);
    static MOCK_STORE: Once = Once::new();

    /// Installs the in-memory mock keyring store for the test binary.
    ///
    /// `keyring_core::set_default_store` is a last-wins `RwLock` swap, so this is
    /// safe even if another test module (e.g. `keyring_policy`) also installs a
    /// mock store; every test below uses a unique service/key id, so a shared
    /// store never causes cross-test interference.
    fn install_mock_store() {
        MOCK_STORE.call_once(|| {
            keyring_core::set_default_store(
                keyring_core::mock::Store::new().expect("mock store creation never fails"),
            );
        });
    }

    fn unique_temp_dir() -> PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!(
            "haven_mls_storage_test_{}_{}",
            std::process::id(),
            id
        ))
    }

    fn unique_key_id(tag: &str) -> String {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        format!("mls.test.{tag}.{}.{id}", std::process::id())
    }

    #[test]
    fn database_path_is_session_sqlite() {
        let config = StorageConfig::new("/tmp/haven-mls");
        assert_eq!(
            config.database_path(),
            PathBuf::from("/tmp/haven-mls/session.sqlite")
        );
    }

    #[test]
    fn legacy_database_path_is_haven_mdk_db() {
        let config = StorageConfig::new("/tmp/haven-mls");
        assert_eq!(
            config.legacy_database_path(),
            PathBuf::from("/tmp/haven-mls/haven_mdk.db")
        );
    }

    #[test]
    fn storage_options_are_hardened_defaults() {
        let opts = StorageConfig::storage_options();
        assert!(opts.secure_delete, "secure_delete must be on");
        assert!(
            opts.cipher_memory_security,
            "cipher_memory_security must be on"
        );
        assert_eq!(opts.cipher_compatibility, 4);
    }

    #[test]
    fn in_memory_storage_opens() {
        let storage = StorageConfig::in_memory_storage();
        assert!(storage.is_ok(), "in-memory MLS storage should open");
    }

    #[test]
    fn passphrase_is_64_lowercase_hex_and_stable() {
        install_mock_store();
        let key_id = unique_key_id("stable");

        let first = get_or_create_passphrase(SERVICE_ID, &key_id).expect("mint passphrase");
        assert_eq!(first.len(), 64, "hex of 32 bytes is 64 chars");
        assert!(
            first
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "passphrase must be lowercase hex"
        );

        // A second read returns the SAME persisted passphrase (no re-mint).
        let second = get_or_create_passphrase(SERVICE_ID, &key_id).expect("read passphrase");
        assert_eq!(first.as_str(), second.as_str());
    }

    #[test]
    fn distinct_key_ids_yield_distinct_passphrases() {
        install_mock_store();
        let a = get_or_create_passphrase(SERVICE_ID, &unique_key_id("a")).unwrap();
        let b = get_or_create_passphrase(SERVICE_ID, &unique_key_id("b")).unwrap();
        assert_ne!(a.as_str(), b.as_str());
    }

    #[test]
    fn open_encrypted_roundtrips_and_rejects_wrong_key() {
        install_mock_store();
        let dir = unique_temp_dir();
        let config = StorageConfig::new(&dir);

        // First open provisions the key + creates the encrypted DB.
        config
            .open_encrypted_storage()
            .expect("first open creates the encrypted MLS DB");

        // Reopening with the same keyring-provisioned key succeeds.
        config
            .open_encrypted_storage()
            .expect("reopen with the same key succeeds");

        // A different key must NOT decrypt the same file.
        let wrong_key = SqlCipherKey::new("a-different-passphrase").unwrap();
        let wrong = SqliteAccountStorage::open_encrypted_with_options(
            config.database_path(),
            &wrong_key,
            StorageConfig::storage_options(),
        );
        assert!(wrong.is_err(), "a wrong key must fail to open the DB");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn destroy_legacy_key_is_idempotent() {
        install_mock_store();
        // No legacy entry present ⇒ idempotent success.
        destroy_legacy_mls_key_material().expect("destroying an absent legacy key is a no-op");

        // Provision the legacy entry, then destroy it, then destroy again.
        let _ = get_or_create_passphrase(SERVICE_ID, LEGACY_MLS_DB_KEY_ID).unwrap();
        destroy_legacy_mls_key_material().expect("destroy existing legacy key");
        destroy_legacy_mls_key_material().expect("second destroy is still a no-op");
    }

    #[test]
    fn keyring_constants_are_valid() {
        assert_eq!(SERVICE_ID, "com.oblivioustech.haven");
        assert_eq!(MLS_DB_KEY_ID, "mls.session.key.default");
        assert_eq!(LEGACY_MLS_DB_KEY_ID, "mdk.db.key.default");
        assert_eq!(MLS_DB_FILENAME, "session.sqlite");
        assert_eq!(LEGACY_MLS_DB_FILENAME, "haven_mdk.db");
    }
}
