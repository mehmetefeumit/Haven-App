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

/// Machine-readable marker embedded in — and ONLY in — the error
/// [`LiveSessionGuard::acquire`] returns when the database is already claimed by
/// a live session (Rule 14).
///
/// # This marker is for HUMANS, not for control flow
///
/// Every failure crossing the FFI boundary is flattened to a prose `String`, and
/// "an MLS session is already open" is otherwise indistinguishable in a log from
/// a locked keyring or a full disk. The marker makes that one condition
/// greppable in a bug report or an E2E log.
///
/// It is deliberately NOT the way code answers "is the guard held?". Haven's
/// error strings interpolate remote-authored text (see [`is_session_live`] for
/// the concrete chain), so a substring test over them is remotely influenceable.
/// Code must call [`is_session_live`], which reads the registry directly and has
/// no untrusted input. Treat this constant as a log token: if it ever appears in
/// a `contains` that drives a decision, that is a bug.
pub const SESSION_BUSY_MARKER: &str = "HAVEN_E_SESSION_BUSY";

/// Reports whether a live session is currently registered for `db_path`.
///
/// This asks the registry directly instead of pattern-matching an error
/// message, and it is the ONLY supported way for a caller to answer "is the
/// Rule-14 guard held on this database?".
///
/// # Why not classify the error string
///
/// The obvious alternative — test a flattened FFI error for
/// [`SESSION_BUSY_MARKER`] — is unsafe, and not for a subtle reason. Haven's
/// error strings interpolate remote-authored text: a circle admin controls the
/// group's routing relay list, and the live-sync relay gate formats the
/// offending URL into its error (`relay/live_sync/session.rs`). A relay URL of
/// `ws://host/HAVEN_E_SESSION_BUSY` therefore produces an unrelated error that a
/// substring test would classify as session-busy — handing a remote party a
/// one-bit control channel over a local recovery decision. Redaction does not
/// help: `redact_hex_sequences` only collapses long hex runs, so it preserves a
/// planted marker as faithfully as a genuine one.
///
/// A registry lookup has no such input. It answers from process-local state
/// that no remote party can write.
///
/// # This is advisory, not exclusion
///
/// The answer is a snapshot: a session may be opened or closed the instant
/// after it returns. That is fine for its purpose (deciding whether a recovery
/// step is worth attempting), and it must NEVER be used to decide whether
/// opening is safe — [`LiveSessionGuard::acquire`] is the only authority on
/// that, because only a CAS can be atomic with respect to the open.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if `db_path` cannot be reduced to a
/// canonical registry key — the same fail-closed condition
/// [`LiveSessionGuard::acquire`] hits, surfaced rather than reported as "not
/// live", which would be a fail-open answer.
pub fn is_session_live(db_path: &Path) -> Result<bool> {
    let key = canonical_session_key(db_path)?;
    Ok(live_sessions()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains(&key))
}

/// Normalizes a `session.sqlite` path to a stable registry key.
///
/// The DB file itself may not exist yet on a first open, so the *parent
/// directory* (which the caller creates before opening) is canonicalized and
/// the file name re-attached. This makes two spellings of the same file
/// (relative vs absolute, `.`/`..` segments, a symlinked parent) collide on one
/// key.
///
/// # Why this fails closed
///
/// An earlier version fell back to the raw path when canonicalization failed,
/// documented as "a fail-safe that can only ever be *stricter*". That is true
/// only for the MERGE direction (it never unifies two distinct files). In the
/// other direction it is a fail-**open** on a confidentiality control: if one
/// caller canonicalizes successfully and another hits a transient failure, the
/// two compute DIFFERENT keys for the SAME file, both acquire, and two live
/// [`AccountDeviceSession`]s hydrate from one database — which is exactly the
/// epoch/generation reuse Rule 14 exists to prevent (see the type doc below).
///
/// On Android this is not hypothetical: `/data/user/0/<pkg>` is a symlink to
/// `/data/data/<pkg>`, so the canonical and raw spellings genuinely differ, and
/// the fallback would produce two keys rather than a stricter one.
///
/// Callers create the parent directory before opening (`CoreCircleManager::new`
/// runs `create_dir_all` before `SessionManager::new`), so a failure here means
/// something is genuinely wrong with the data directory — refusing to open is
/// both correct and safe.
///
/// # Errors
///
/// Returns [`NostrError::StorageError`] if `db_path` has no parent or no file
/// name, or if the parent directory cannot be canonicalized.
fn canonical_session_key(db_path: &Path) -> Result<PathBuf> {
    let (Some(parent), Some(name)) = (db_path.parent(), db_path.file_name()) else {
        return Err(NostrError::StorageError(
            "session database path has no parent directory or no file name \
             (Rule 14: refusing to open without a canonical registry key)"
                .to_string(),
        ));
    };
    let canonical_parent = parent.canonicalize().map_err(|_| {
        NostrError::StorageError(
            "could not canonicalize the session database's parent directory \
             (Rule 14: refusing to open rather than risk two registry keys for \
              one database)"
                .to_string(),
        )
    })?;
    Ok(canonical_parent.join(name))
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
    /// database file, or if `db_path` cannot be reduced to a canonical registry
    /// key (see [`canonical_session_key`] — that case fails closed rather than
    /// risking two keys for one database).
    pub fn acquire(db_path: &Path) -> Result<Self> {
        let key = canonical_session_key(db_path)?;
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
            // The marker leads the message so it survives any outer wrapping
            // (`thiserror` prefixes "Storage error: ") and stays greppable. It
            // is a LOG token only — code asks `is_session_live` instead of
            // matching this prose.
            Err(NostrError::StorageError(format!(
                "{SESSION_BUSY_MARKER}: an MLS session is already open on this \
                 database (Rule 14: exactly one live session per DB file)"
            )))
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

    // -----------------------------------------------------------------------
    // LiveSessionGuard / canonical_session_key (Security Rule 14).
    //
    // This module previously had NO direct coverage of the guard — the only
    // Rule-14 test lived one level up in `mls::manager` and exercised it through
    // a full `SessionManager::new_unencrypted`. These pin the registry itself,
    // and in particular the fail-CLOSED behaviour of the key derivation, whose
    // fail-open predecessor could hand two keys to one database.
    // -----------------------------------------------------------------------

    #[test]
    fn guard_rejects_a_second_acquire_and_frees_the_path_on_drop() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");

        let first = LiveSessionGuard::acquire(&db).expect("first acquire");
        assert!(
            LiveSessionGuard::acquire(&db).is_err(),
            "Rule 14: a second live session on the same DB must fail closed"
        );

        drop(first);
        // Re-acquirable after the guard drops, or a legitimately-closed session
        // would lock the database out for the rest of the process.
        drop(LiveSessionGuard::acquire(&db).expect("re-acquire after drop"));
    }

    #[test]
    fn busy_error_stays_greppable_after_the_string_flattening_ffi_does() {
        // The marker's only job is diagnosability, so pin the shape a human
        // actually greps: the FFI-flattened string, not the `NostrError`
        // variant. `thiserror` prefixes "Storage error: ", so anything anchored
        // at the start of the message would not survive.
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");
        let _held = LiveSessionGuard::acquire(&db).expect("first acquire");

        let flattened = LiveSessionGuard::acquire(&db)
            .expect_err("second acquire must fail")
            .to_string();

        assert!(
            flattened.contains(SESSION_BUSY_MARKER),
            "the already-live failure must stay identifiable in a log: {flattened}"
        );
    }

    #[test]
    fn is_session_live_tracks_the_guard_and_is_not_a_constant() {
        // Both directions in one test, because either alone is satisfiable by a
        // function that ignores its argument.
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");

        assert!(
            !is_session_live(&db).expect("query before acquire"),
            "no session has been opened yet"
        );
        let held = LiveSessionGuard::acquire(&db).expect("acquire");
        assert!(
            is_session_live(&db).expect("query while held"),
            "the registry must report the live session the FGS is contending with"
        );
        drop(held);
        assert!(
            !is_session_live(&db).expect("query after drop"),
            "a released guard must not leave the database looking permanently \
             busy — that would make recovery unreachable forever"
        );
    }

    #[test]
    fn is_session_live_answers_per_database_not_globally() {
        // A global "any session live" answer would tell the caller to reclaim
        // over an unrelated database.
        let a = tempfile::tempdir().expect("tempdir a");
        let b = tempfile::tempdir().expect("tempdir b");
        let db_a = a.path().join("session.sqlite");
        let db_b = b.path().join("session.sqlite");

        let _held_a = LiveSessionGuard::acquire(&db_a).expect("acquire a");
        assert!(is_session_live(&db_a).expect("a is live"));
        assert!(
            !is_session_live(&db_b).expect("b is not live"),
            "holding one database must not report a different one as busy"
        );
    }

    #[test]
    fn is_session_live_fails_closed_rather_than_reporting_not_live() {
        // Mirrors `acquire`: an underivable key must surface as an error. `false`
        // would be a fail-OPEN answer ("nothing is live, go ahead"), which is the
        // wrong default for a question asked in order to decide about recovery.
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = dir.path().join("does-not-exist").join("session.sqlite");

        assert!(
            is_session_live(&missing).is_err(),
            "a non-canonicalizable path must error, never answer `false`"
        );
    }

    #[test]
    fn remote_authored_text_cannot_forge_a_live_session() {
        // The reason this is a registry lookup and not a substring test over an
        // error string. A circle admin controls the group's routing relays, and
        // the live-sync relay gate formats the offending URL into its error —
        // so a relay of `ws://host/HAVEN_E_SESSION_BUSY` yields an unrelated
        // error carrying the marker verbatim. Redaction does not strip it:
        // `redact_hex_sequences` only collapses long hex runs.
        //
        // Assert on the actual redactor rather than a hand-written string, so
        // this keeps testing the real sanitizer if it changes.
        let hostile = crate::util::redact_hex_sequences(
            "plaintext ws:// not allowed for the live-sync engine: \
             ws://evil.example/HAVEN_E_SESSION_BUSY",
        );
        assert!(
            hostile.contains(SESSION_BUSY_MARKER),
            "precondition: the marker survives redaction, which is exactly why \
             classifying error prose would be remotely influenceable"
        );

        // The supported query is unaffected: it never reads a message at all.
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("session.sqlite");
        assert!(
            !is_session_live(&db).expect("query"),
            "no error string can make the registry claim a session is live"
        );
    }

    #[test]
    fn guard_allows_distinct_databases_concurrently() {
        let a = tempfile::tempdir().expect("tempdir a");
        let b = tempfile::tempdir().expect("tempdir b");

        let _ga = LiveSessionGuard::acquire(&a.path().join("session.sqlite")).expect("acquire a");
        let _gb = LiveSessionGuard::acquire(&b.path().join("session.sqlite")).expect("acquire b");
    }

    #[test]
    fn two_spellings_of_one_database_collide_on_a_single_key() {
        // THE property the registry exists for. If these ever resolve to
        // different keys, both acquires succeed and two `AccountDeviceSession`s
        // hydrate from one file — the epoch/generation reuse Rule 14 prevents.
        let dir = tempfile::tempdir().expect("tempdir");
        let nested = dir.path().join("nested");
        std::fs::create_dir(&nested).expect("create nested");

        let direct = nested.join("session.sqlite");
        let indirect = dir
            .path()
            .join("nested")
            .join("..")
            .join("nested")
            .join("session.sqlite");

        // Assert the KEY EQUALITY directly. Going only through `acquire` would
        // be satisfied by any `Err` — including one from a broken
        // `canonical_session_key` — so a regression that stopped deriving keys
        // at all would leave this green while proving nothing about collision.
        assert_eq!(
            canonical_session_key(&direct).expect("direct key"),
            canonical_session_key(&indirect).expect("indirect key"),
            "two spellings of one file must reduce to ONE registry key"
        );

        // Then the integration half: the registry actually rejects the second.
        let _held = LiveSessionGuard::acquire(&direct).expect("acquire direct");
        assert!(
            LiveSessionGuard::acquire(&indirect).is_err(),
            "a `..` round-trip through the same directory must resolve to the \
             SAME registry key, not a second one"
        );
    }

    #[test]
    fn canonical_key_fails_closed_when_the_parent_cannot_be_canonicalized() {
        // The regression test for the fail-open this replaced. A missing parent
        // used to fall back to the raw path, so a caller that COULD canonicalize
        // and one that could not would register two different keys for one file.
        // Refusing to produce a key is the only safe answer.
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = dir.path().join("does-not-exist").join("session.sqlite");

        assert!(
            canonical_session_key(&missing).is_err(),
            "a non-canonicalizable parent must fail, never fall back to the raw path"
        );
        assert!(
            LiveSessionGuard::acquire(&missing).is_err(),
            "acquire must propagate the failure rather than register a raw-path key"
        );
    }

    #[test]
    fn canonical_key_fails_closed_on_a_path_with_no_file_name() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert!(
            canonical_session_key(dir.path().join("..").as_path()).is_err(),
            "a path whose final component is `..` has no file name and must fail"
        );
    }

    #[test]
    fn canonical_key_error_carries_no_path() {
        // Rule 8 / Rule 6: the message is a fixed literal. A path in an error
        // that crosses the FFI would leak the data directory layout.
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = dir.path().join("does-not-exist").join("session.sqlite");
        let err = canonical_session_key(&missing).expect_err("must fail");
        let rendered = err.to_string();

        assert!(
            !rendered.contains(dir.path().to_str().expect("utf8")),
            "the error must not embed the database path: {rendered}"
        );
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
